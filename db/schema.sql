-- DB01 / T004: 상품, 재고로트, 판매기록
CREATE TABLE IF NOT EXISTS products (
    id BIGINT NOT NULL AUTO_INCREMENT,
    name TEXT NOT NULL,
    sale_price_won BIGINT NOT NULL,
    purchase_cost_won BIGINT NOT NULL,

    PRIMARY KEY (id),
    CONSTRAINT ck_products_name CHECK (REGEXP_LIKE(name, '[^[:space:]]')),
    CONSTRAINT ck_products_sale_price CHECK (sale_price_won > 0),
    CONSTRAINT ck_products_purchase_cost CHECK (purchase_cost_won >= 0)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;

CREATE TABLE IF NOT EXISTS stock_lots (
    id BIGINT NOT NULL AUTO_INCREMENT,
    product_id BIGINT NOT NULL,
    registered_on DATE NOT NULL,
    recorded_at_utc DATETIME(6) NOT NULL,
    expires_on DATE NULL,
    initial_quantity BIGINT NOT NULL,
    remaining_quantity BIGINT NOT NULL,
    unit_cost_won BIGINT NOT NULL,
    request_key CHAR(36) NOT NULL,
    request_fingerprint CHAR(64) NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uq_stock_lots_request_key (request_key),
    KEY ix_stock_lots_product_expiry (product_id, expires_on, recorded_at_utc, id),
    CONSTRAINT fk_stock_lots_product FOREIGN KEY (product_id) REFERENCES products (id),
    CONSTRAINT ck_stock_lots_initial_quantity CHECK (initial_quantity > 0),
    CONSTRAINT ck_stock_lots_remaining_quantity CHECK (remaining_quantity BETWEEN 0 AND initial_quantity),
    CONSTRAINT ck_stock_lots_unit_cost CHECK (unit_cost_won >= 0)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;

CREATE TABLE IF NOT EXISTS sales (
    id BIGINT NOT NULL AUTO_INCREMENT,
    product_id BIGINT NOT NULL,
    sold_on DATE NOT NULL,
    recorded_at_utc DATETIME(6) NOT NULL,
    quantity BIGINT NOT NULL,
    request_key CHAR(36) NOT NULL,
    request_fingerprint CHAR(64) NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uq_sales_request_key (request_key),
    KEY ix_sales_product_date (product_id, sold_on),
    CONSTRAINT fk_sales_product FOREIGN KEY (product_id) REFERENCES products (id),
    CONSTRAINT ck_sales_quantity CHECK (quantity > 0)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;

-- DB02 / T005: 판매일 확인, 폐기기록, 재고변동이력
CREATE TABLE IF NOT EXISTS sales_day_confirmations (
    sales_on DATE NOT NULL,
    confirmed_at_utc DATETIME(6) NOT NULL,

    PRIMARY KEY (sales_on)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;

CREATE TABLE IF NOT EXISTS waste_records (
    id BIGINT NOT NULL AUTO_INCREMENT,
    lot_id BIGINT NOT NULL,
    disposed_on DATE NOT NULL,
    recorded_at_utc DATETIME(6) NOT NULL,
    quantity BIGINT NOT NULL,
    reason TEXT NOT NULL,
    unit_cost_won BIGINT NOT NULL,
    request_key CHAR(36) NOT NULL,
    request_fingerprint CHAR(64) NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uq_waste_records_request_key (request_key),
    KEY ix_waste_records_disposed_lot (disposed_on, lot_id),
    CONSTRAINT fk_waste_records_lot FOREIGN KEY (lot_id) REFERENCES stock_lots (id),
    CONSTRAINT ck_waste_records_quantity CHECK (quantity > 0),
    CONSTRAINT ck_waste_records_reason CHECK (REGEXP_LIKE(reason, '[^[:space:]]')),
    CONSTRAINT ck_waste_records_unit_cost CHECK (unit_cost_won >= 0)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;

CREATE TABLE IF NOT EXISTS inventory_movements (
    id BIGINT NOT NULL AUTO_INCREMENT,
    lot_id BIGINT NOT NULL,
    sale_id BIGINT NULL,
    waste_id BIGINT NULL,
    kind VARCHAR(7) COLLATE utf8mb4_0900_bin NOT NULL,
    quantity_delta BIGINT NOT NULL,
    recorded_at_utc DATETIME(6) NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uq_inventory_movements_receipt ((CASE WHEN kind = 'RECEIPT' THEN lot_id ELSE NULL END)),
    UNIQUE KEY uq_inventory_movements_sale_lot (sale_id, lot_id),
    UNIQUE KEY uq_inventory_movements_waste (waste_id),
    KEY ix_inventory_movements_lot_time (lot_id, recorded_at_utc),
    CONSTRAINT fk_inventory_movements_lot FOREIGN KEY (lot_id) REFERENCES stock_lots (id),
    CONSTRAINT fk_inventory_movements_sale FOREIGN KEY (sale_id) REFERENCES sales (id),
    CONSTRAINT fk_inventory_movements_waste FOREIGN KEY (waste_id) REFERENCES waste_records (id),
    CONSTRAINT ck_inventory_movements_kind_cause_quantity CHECK (
        (kind = 'RECEIPT' AND quantity_delta > 0 AND sale_id IS NULL AND waste_id IS NULL)
        OR (kind = 'SALE' AND quantity_delta < 0 AND sale_id IS NOT NULL AND waste_id IS NULL)
        OR (kind = 'WASTE' AND quantity_delta < 0 AND sale_id IS NULL AND waste_id IS NOT NULL)
    )
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4;
