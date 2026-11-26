#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
    printf 'Usage: bash db/test-schema.sh <mysql command and connection arguments>\n' >&2
    exit 1
fi

mysql_command=("$@")
schema_file="$(dirname -- "${BASH_SOURCE[0]}")/schema.sql"

sql() {
    # Normalize line endings from the Windows MySQL client for local runs.
    "${mysql_command[@]}" --batch --skip-column-names "$@" | sed 's/\r$//'
}

assert_equal() {
    local description=$1 expected=$2 actual=$3
    if [[ $actual != "$expected" ]]; then
        printf '%s failed\nExpected:\n%s\nActual:\n%s\n' "$description" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$description"
}

expect_constraint_error() {
    local code=$1 constraint=$2 statement=$3 output
    if output=$(sql --execute="$statement" 2>&1); then
        printf 'Expected %s (%s) to reject the statement, but it succeeded\n' "$constraint" "$code" >&2
        exit 1
    fi
    if [[ $output != *"ERROR $code ("* || $output != *"$constraint"* ]]; then
        printf 'Expected %s (%s), received:\n%s\n' "$constraint" "$code" "$output" >&2
        exit 1
    fi
    printf 'PASS: %s rejected invalid data (%s)\n' "$constraint" "$code"
}

table_names() {
    sql --execute="SELECT table_name FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY table_name"
}

snapshot() {
    sql <<'SQL'
SELECT * FROM products ORDER BY id;
SELECT * FROM stock_lots ORDER BY id;
SELECT * FROM sales ORDER BY id;
SELECT * FROM sales_day_confirmations ORDER BY sales_on;
SELECT * FROM waste_records ORDER BY id;
SELECT * FROM inventory_movements ORDER BY id;
SQL
}

version=$(sql --execute='SELECT VERSION()')
if [[ $version != 8.4.* ]]; then
    printf 'MySQL 8.4 required, found %s\n' "$version" >&2
    exit 1
fi
printf 'Testing MySQL %s\n' "$version"

database=$(sql --execute='SELECT DATABASE()')
assert_equal 'Database is dedicated to schema CI' 'convenience_inventory_schema_ci' "$database"
existing_objects=$(sql --execute='SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()')
assert_equal 'Database starts empty' '0' "$existing_objects"

sql < "$schema_file"
expected_tables=$'inventory_movements\nproducts\nsales\nsales_day_confirmations\nstock_lots\nwaste_records'
actual_tables=$(table_names)
assert_equal 'Schema creates exactly six expected tables' "$expected_tables" "$actual_tables"

expected_indexes=$(cat <<'INDEXES'
inventory_movements.ix_inventory_movements_lot_time: lot_id, recorded_at_utc
sales.ix_sales_product_date: product_id, sold_on
stock_lots.ix_stock_lots_product_expiry: product_id, expires_on, recorded_at_utc, id
waste_records.ix_waste_records_disposed_lot: disposed_on, lot_id
INDEXES
)
actual_indexes=$(sql <<'SQL'
SELECT CONCAT(table_name, '.', index_name, ': ', GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR ', '))
FROM information_schema.statistics
WHERE table_schema = DATABASE()
    AND index_name IN ('ix_inventory_movements_lot_time', 'ix_sales_product_date',
                       'ix_stock_lots_product_expiry', 'ix_waste_records_disposed_lot')
GROUP BY table_name, index_name
ORDER BY table_name, index_name;
SQL
)
assert_equal 'Schema creates the four expected query indexes' "$expected_indexes" "$actual_indexes"

sql <<'SQL'
INSERT INTO products (id, name, sale_price_won, purchase_cost_won)
VALUES (1, 'Schema CI product', 1500, 900);
INSERT INTO stock_lots (id, product_id, registered_on, recorded_at_utc, expires_on,
                        initial_quantity, remaining_quantity, unit_cost_won, request_key, request_fingerprint)
VALUES (1, 1, '2025-01-01', '2025-01-01 00:00:00.123456', '2025-01-10',
        9, 6, 900, '00000000-0000-4000-8000-000000000001', REPEAT('a', 64));
INSERT INTO sales (id, product_id, sold_on, recorded_at_utc, quantity, request_key, request_fingerprint)
VALUES (1, 1, '2025-01-02', '2025-01-02 00:00:00.123456',
        2, '00000000-0000-4000-8000-000000000002', REPEAT('b', 64));
INSERT INTO sales_day_confirmations (sales_on, confirmed_at_utc)
VALUES ('2025-01-02', '2025-01-02 01:00:00.123456');
INSERT INTO waste_records (id, lot_id, disposed_on, recorded_at_utc, quantity, reason, unit_cost_won,
                           request_key, request_fingerprint)
VALUES (1, 1, '2025-01-03', '2025-01-03 00:00:00.123456', 1, 'Damaged', 900,
        '00000000-0000-4000-8000-000000000003', REPEAT('c', 64));
INSERT INTO inventory_movements (id, lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc)
VALUES (1, 1, NULL, NULL, 'RECEIPT', 9, '2025-01-01 00:00:00.123456'),
       (2, 1, 1, NULL, 'SALE', -2, '2025-01-02 00:00:00.123456'),
       (3, 1, NULL, 1, 'WASTE', -1, '2025-01-03 00:00:00.123456');
SQL

before=$(snapshot)
sql < "$schema_file"
actual_tables=$(table_names)
assert_equal 'Reapplying schema preserves the table list' "$expected_tables" "$actual_tables"
after=$(snapshot)
assert_equal 'Reapplying schema preserves fixture rows in all six tables' "$before" "$after"

expect_constraint_error 3819 ck_products_sale_price 'UPDATE products SET sale_price_won = 0 WHERE id = 1'
expect_constraint_error 1452 fk_stock_lots_product 'UPDATE stock_lots SET product_id = 999 WHERE id = 1'
expect_constraint_error 3819 ck_stock_lots_remaining_quantity 'UPDATE stock_lots SET remaining_quantity = initial_quantity + 1 WHERE id = 1'
expect_constraint_error 3819 ck_sales_quantity 'UPDATE sales SET quantity = 0 WHERE id = 1'
expect_constraint_error 1062 PRIMARY "INSERT INTO sales_day_confirmations (sales_on, confirmed_at_utc)
    VALUES ('2025-01-02', '2025-01-02 02:00:00')"
expect_constraint_error 3819 ck_waste_records_reason "UPDATE waste_records SET reason = ' ' WHERE id = 1"
expect_constraint_error 1062 uq_waste_records_request_key 'INSERT INTO waste_records
    (lot_id, disposed_on, recorded_at_utc, quantity, reason, unit_cost_won, request_key, request_fingerprint)
    SELECT lot_id, disposed_on, recorded_at_utc, quantity, reason, unit_cost_won, request_key, request_fingerprint
    FROM waste_records WHERE id = 1'
expect_constraint_error 3819 ck_inventory_movements_kind_cause_quantity 'UPDATE inventory_movements SET quantity_delta = 1 WHERE id = 2'
expect_constraint_error 1062 uq_inventory_movements_receipt 'INSERT INTO inventory_movements
    (lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc)
    SELECT lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc FROM inventory_movements WHERE id = 1'
expect_constraint_error 1062 uq_inventory_movements_sale_lot 'INSERT INTO inventory_movements
    (lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc)
    SELECT lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc FROM inventory_movements WHERE id = 2'
expect_constraint_error 1062 uq_inventory_movements_waste 'INSERT INTO inventory_movements
    (lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc)
    SELECT lot_id, sale_id, waste_id, kind, quantity_delta, recorded_at_utc FROM inventory_movements WHERE id = 3'
