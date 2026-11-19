"""T012: verify sales and their effects in MySQL independently of the UI.

The T009 integration setup supplies the inventory_case fixture. It owns
isolated test data and exposes the fixed local date as today and a fresh,
validated test-DB connection as connect(). The following adapter methods
call the actual inventory service with the supplied connection:

- create_product(connection, *, name, sale_price_won, purchase_cost_won) -> product ID
- register_lot(connection, *, product_id, quantity, expires_on, request_key) -> lot ID
- stock_total(connection, *, product_id) -> total quantity on hand
- record_sale(connection, *, product_id, quantity, request_key) -> (status, sale ID)

The adapter maps service results to "sold", "insufficient_stock", or
"request_conflict". Both rejections return None for the ID. Normal writes
are committed by the service so a fresh connection can verify them.
"""

from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from dataclasses import dataclass
from datetime import timedelta
from threading import Barrier
from uuid import uuid4


@dataclass(frozen=True)
class _StoredInventory:
    balances: dict[int, int]
    sales: tuple[tuple[int, int, str], ...]
    movements: tuple[tuple[int, int | None, str, int], ...]


def _seed(case, *lots):
    """Register a product and lots as (quantity, days until expiry) pairs."""
    with closing(case.connect()) as connection:
        product_id = case.create_product(
            connection,
            name=f"T012 {uuid4()}",
            sale_price_won=2000,
            purchase_cost_won=1100,
        )
        lot_ids = [
            case.register_lot(
                connection,
                product_id=product_id,
                quantity=quantity,
                expires_on=case.today + timedelta(days=days),
                request_key=str(uuid4()),
            )
            for quantity, days in lots
        ]
    return product_id, lot_ids


def _snapshot(case, product_id):
    with closing(case.connect()) as connection, closing(connection.cursor()) as cursor:
        cursor.execute(
            "SELECT id, remaining_quantity FROM stock_lots WHERE product_id = %s",
            (product_id,),
        )
        balances = dict(cursor.fetchall())

        cursor.execute(
            "SELECT id, quantity, request_key FROM sales WHERE product_id = %s ORDER BY id",
            (product_id,),
        )
        sales = tuple(cursor.fetchall())

        cursor.execute(
            """
            SELECT movement.lot_id, movement.sale_id, movement.kind, movement.quantity_delta
            FROM inventory_movements AS movement
            JOIN stock_lots AS lot ON lot.id = movement.lot_id
            WHERE lot.product_id = %s
            ORDER BY movement.id
            """,
            (product_id,),
        )
        return _StoredInventory(balances, sales, tuple(cursor.fetchall()))


def _record_sale(case, product_id, quantity, request_key):
    with closing(case.connect()) as connection:
        return case.record_sale(
            connection,
            product_id=product_id,
            quantity=quantity,
            request_key=request_key,
        )


def _assert_single_sale(before, after, sale_id, request_key, quantity, deductions):
    assert sale_id is not None
    assert after.sales == ((sale_id, quantity, request_key),)
    assert after.balances == {
        lot_id: balance - deductions.get(lot_id, 0) for lot_id, balance in before.balances.items()
    }
    expected_movements = Counter(
        (lot_id, sale_id, "SALE", -deduction) for lot_id, deduction in deductions.items()
    )
    assert Counter(after.movements) == Counter(before.movements) + expected_movements


class TestInventory:
    def test_s1_1_separate_lots_add_up_to_thirteen(self, inventory_case):
        product_id, (early, late) = _seed(inventory_case, (5, 1), (8, 3))

        with closing(inventory_case.connect()) as connection:
            assert inventory_case.stock_total(connection, product_id=product_id) == 13
        stored = _snapshot(inventory_case, product_id)

        assert stored.balances == {early: 5, late: 8}
        assert stored.sales == ()
        assert Counter(stored.movements) == Counter(
            [(early, None, "RECEIPT", 5), (late, None, "RECEIPT", 8)]
        )

    def test_s1_2_sale_uses_the_earliest_expiry_first(self, inventory_case):
        # Register the later-expiring lot first to distinguish expiry order from entry order.
        product_id, (late, early) = _seed(inventory_case, (5, 3), (2, 0))
        before = _snapshot(inventory_case, product_id)
        request_key = str(uuid4())

        status, sale_id = _record_sale(inventory_case, product_id, 4, request_key)

        after = _snapshot(inventory_case, product_id)
        assert status == "sold"
        assert after.balances == {early: 0, late: 3}
        _assert_single_sale(before, after, sale_id, request_key, 4, {early: 2, late: 2})

    def test_s1_3_expired_stock_cannot_cover_a_short_sale(self, inventory_case):
        product_id, (expired, available) = _seed(inventory_case, (3, -1), (5, 2))
        before = _snapshot(inventory_case, product_id)
        assert before.balances == {expired: 3, available: 5}

        result = _record_sale(inventory_case, product_id, 6, str(uuid4()))

        assert result == ("insufficient_stock", None)
        assert _snapshot(inventory_case, product_id) == before

    def test_same_key_and_input_returns_existing_sale(self, inventory_case):
        product_id, (lot_id,) = _seed(inventory_case, (8, 2))
        before = _snapshot(inventory_case, product_id)
        request_key = str(uuid4())

        status, sale_id = _record_sale(inventory_case, product_id, 3, request_key)
        first = _snapshot(inventory_case, product_id)
        replay_result = _record_sale(inventory_case, product_id, 3, request_key)

        assert status == "sold"
        _assert_single_sale(before, first, sale_id, request_key, 3, {lot_id: 3})
        assert replay_result == ("sold", sale_id)
        assert _snapshot(inventory_case, product_id) == first

    def test_same_key_with_a_different_quantity_conflicts(self, inventory_case):
        product_id, (lot_id,) = _seed(inventory_case, (8, 2))
        before = _snapshot(inventory_case, product_id)
        request_key = str(uuid4())

        status, sale_id = _record_sale(inventory_case, product_id, 3, request_key)
        first = _snapshot(inventory_case, product_id)
        conflict_result = _record_sale(inventory_case, product_id, 2, request_key)

        assert status == "sold"
        _assert_single_sale(before, first, sale_id, request_key, 3, {lot_id: 3})
        assert conflict_result == ("request_conflict", None)
        assert _snapshot(inventory_case, product_id) == first

    def test_concurrent_sales_cannot_both_use_the_same_stock(self, inventory_case):
        product_id, (lot_id,) = _seed(inventory_case, (5, 2))
        before = _snapshot(inventory_case, product_id)
        ready = Barrier(2, timeout=10)

        def sell_four(request_key):
            with closing(inventory_case.connect()) as connection:
                with closing(connection.cursor()) as cursor:
                    cursor.execute("SELECT CONNECTION_ID()")
                    (connection_id,) = cursor.fetchone()
                # Both sessions must be connected before either sends the sale.
                ready.wait()
                status, sale_id = inventory_case.record_sale(
                    connection,
                    product_id=product_id,
                    quantity=4,
                    request_key=request_key,
                )
                return connection_id, request_key, status, sale_id

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(sell_four, str(uuid4()))
            second = pool.submit(sell_four, str(uuid4()))
            results = (first.result(timeout=20), second.result(timeout=20))

        assert len({row[0] for row in results}) == 2
        assert sorted(row[2] for row in results) == ["insufficient_stock", "sold"]
        _, winning_key, _, sale_id = next(row for row in results if row[2] == "sold")
        after = _snapshot(inventory_case, product_id)
        assert after.balances == {lot_id: 1}
        _assert_single_sale(before, after, sale_id, winning_key, 4, {lot_id: 4})
