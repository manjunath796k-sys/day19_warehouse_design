-- ============================================================
-- DAY 19 — DATA WAREHOUSE DESIGN & ETL
-- ============================================================

USE day_19;

-- ============================================================
-- 0. RAW SOURCE TABLES
-- Assumption: CSV files have been imported into these tables.
-- Raw tables should preserve source data as received.
-- ============================================================

CREATE TABLE IF NOT EXISTS raw_customers (
    CustomerID      VARCHAR(30),
    CustomerName    VARCHAR(150),
    Segment         VARCHAR(50),
    Region          VARCHAR(50),
    City            VARCHAR(100),
    State           VARCHAR(100),
    SignupDate      DATE,
    AgeGroup        VARCHAR(30)
);

CREATE TABLE IF NOT EXISTS raw_orders (
    OrderID           VARCHAR(30),
    OrderDate         DATE,
    CustomerID        VARCHAR(30),
    ProductCategory   VARCHAR(100),
    Product           VARCHAR(150),
    Quantity          DECIMAL(18,2),
    Discount          DECIMAL(10,4),
    Sales             DECIMAL(18,2),
    Profit            DECIMAL(18,2),
    PaymentMethod     VARCHAR(80),
    OrderStatus       VARCHAR(50)
);


-- ============================================================
-- 1. STAGING LAYER
-- Purpose:
--   * remove exact duplicate source rows
--   * standardize text
--   * validate business values
--   * identify orphan CustomerIDs
-- ============================================================

DROP TEMPORARY TABLE IF EXISTS stg_customers;
CREATE TEMPORARY TABLE stg_customers AS
SELECT
    CustomerID,
    TRIM(CustomerName) AS CustomerName,
    CASE
        WHEN LOWER(TRIM(Segment)) = 'consumer' THEN 'Consumer'
        WHEN LOWER(TRIM(Segment)) = 'corporate' THEN 'Corporate'
        WHEN LOWER(TRIM(Segment)) = 'home office' THEN 'Home Office'
        ELSE COALESCE(NULLIF(TRIM(Segment), ''), 'Unknown')
    END AS Segment,
    CASE
        WHEN LOWER(TRIM(Region)) = 'north' THEN 'North'
        WHEN LOWER(TRIM(Region)) = 'south' THEN 'South'
        WHEN LOWER(TRIM(Region)) = 'east' THEN 'East'
        WHEN LOWER(TRIM(Region)) = 'west' THEN 'West'
        ELSE COALESCE(NULLIF(TRIM(Region), ''), 'Unknown')
    END AS Region,
    TRIM(City) AS City,
    TRIM(State) AS State,
    SignupDate,
    TRIM(AgeGroup) AS AgeGroup
FROM (
    SELECT
        rc.*,
        ROW_NUMBER() OVER (
            PARTITION BY CustomerID
            ORDER BY CustomerID
        ) AS rn
    FROM raw_customers rc
) x
WHERE rn = 1;


DROP TEMPORARY TABLE IF EXISTS stg_orders;
CREATE TEMPORARY TABLE stg_orders AS
SELECT
    OrderID,
    OrderDate,
    CustomerID,
    CASE
        WHEN LOWER(TRIM(ProductCategory)) = 'electronics' THEN 'Electronics'
        WHEN LOWER(TRIM(ProductCategory)) = 'office supplies' THEN 'Office Supplies'
        WHEN LOWER(TRIM(ProductCategory)) = 'furniture' THEN 'Furniture'
        WHEN LOWER(TRIM(ProductCategory)) = 'accessories' THEN 'Accessories'
        WHEN LOWER(TRIM(ProductCategory)) = 'books' THEN 'Books'
        WHEN LOWER(TRIM(ProductCategory)) = 'clothing' THEN 'Clothing'
        ELSE NULLIF(TRIM(ProductCategory), '')
    END AS ProductCategory,
    CASE
        WHEN LOWER(TRIM(Product)) = 'laptop' THEN 'Laptop'
        WHEN LOWER(TRIM(Product)) = 'mouse' THEN 'Mouse'
        WHEN LOWER(TRIM(Product)) = 'keyboard' THEN 'Keyboard'
        ELSE NULLIF(TRIM(Product), '')
    END AS Product,
    Quantity,
    Discount,
    Sales,
    Profit,
    CASE
        WHEN LOWER(TRIM(PaymentMethod)) = 'upi' THEN 'UPI'
        WHEN LOWER(TRIM(PaymentMethod)) = 'netbanking' THEN 'NetBanking'
        WHEN LOWER(TRIM(PaymentMethod)) = 'net banking' THEN 'NetBanking'
        WHEN LOWER(TRIM(PaymentMethod)) = 'cash on delivery' THEN 'Cash on Delivery'
        WHEN LOWER(TRIM(PaymentMethod)) = 'card' THEN 'Card'
        ELSE NULLIF(TRIM(PaymentMethod), '')
    END AS PaymentMethod,
    CASE
        WHEN LOWER(TRIM(OrderStatus)) = 'delivered' THEN 'Delivered'
        WHEN LOWER(TRIM(OrderStatus)) = 'shipped' THEN 'Shipped'
        WHEN LOWER(TRIM(OrderStatus)) = 'cancelled' THEN 'Cancelled'
        WHEN LOWER(TRIM(OrderStatus)) = 'returned' THEN 'Returned'
        ELSE NULLIF(TRIM(OrderStatus), '')
    END AS OrderStatus
FROM (
    SELECT
        ro.*,
        ROW_NUMBER() OVER (
            PARTITION BY
                OrderID, OrderDate, CustomerID, ProductCategory, Product,
                Quantity, Discount, Sales, Profit, PaymentMethod, OrderStatus
            ORDER BY OrderID
        ) AS rn
    FROM raw_orders ro
) x
WHERE rn = 1
  AND Quantity > 0
  AND Sales IS NOT NULL;


-- ============================================================
-- 2. HOLD ORPHAN CUSTOMER ORDERS IN STAGING
-- Do not silently load these rows into the warehouse.
-- ============================================================

DROP TABLE IF EXISTS stg_orphan_orders;
CREATE TABLE stg_orphan_orders AS
SELECT so.*
FROM stg_orders so
LEFT JOIN stg_customers sc
    ON so.CustomerID = sc.CustomerID
WHERE sc.CustomerID IS NULL;


-- ============================================================
-- 3. WAREHOUSE DIMENSION TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS dim_customer (
    CustomerSK      BIGINT AUTO_INCREMENT PRIMARY KEY,
    CustomerID      VARCHAR(30) NOT NULL,
    CustomerName    VARCHAR(150),
    Segment         VARCHAR(50),
    Region          VARCHAR(50),
    City            VARCHAR(100),
    State           VARCHAR(100),
    SignupDate      DATE,
    AgeGroup        VARCHAR(30),
    EffectiveFrom   DATE NOT NULL,
    EffectiveTo     DATE NOT NULL,
    IsCurrent       BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE KEY uq_customer_version (
        CustomerID, EffectiveFrom
    ),
    INDEX ix_customer_business_key (CustomerID)
);


CREATE TABLE IF NOT EXISTS dim_product (
    ProductSK       BIGINT AUTO_INCREMENT PRIMARY KEY,
    ProductName     VARCHAR(150) NOT NULL,
    ProductCategory VARCHAR(100) NOT NULL,
    UNIQUE KEY uq_product (ProductName, ProductCategory)
);


CREATE TABLE IF NOT EXISTS dim_date (
    DateSK          INT PRIMARY KEY,
    FullDate        DATE NOT NULL UNIQUE,
    Year            INT NOT NULL,
    Quarter         INT NOT NULL,
    Month           INT NOT NULL,
    MonthName       VARCHAR(20) NOT NULL,
    Day             INT NOT NULL,
    DayOfWeek       VARCHAR(20) NOT NULL
);


CREATE TABLE IF NOT EXISTS dim_payment_method (
    PaymentMethodSK INT AUTO_INCREMENT PRIMARY KEY,
    PaymentMethod   VARCHAR(80) NOT NULL UNIQUE
);


-- ============================================================
-- 4. FACT TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS fact_sales (
    SalesSK          BIGINT AUTO_INCREMENT PRIMARY KEY,
    OrderID          VARCHAR(30) NOT NULL,
    DateSK           INT NOT NULL,
    CustomerSK       BIGINT NOT NULL,
    ProductSK        BIGINT NOT NULL,
    PaymentMethodSK  INT NOT NULL,
    OrderStatus      VARCHAR(50),
    Quantity         DECIMAL(18,2),
    Discount         DECIMAL(10,4),
    Sales            DECIMAL(18,2),
    Profit           DECIMAL(18,2),

    CONSTRAINT fk_fact_date
        FOREIGN KEY (DateSK) REFERENCES dim_date(DateSK),

    CONSTRAINT fk_fact_customer
        FOREIGN KEY (CustomerSK) REFERENCES dim_customer(CustomerSK),

    CONSTRAINT fk_fact_product
        FOREIGN KEY (ProductSK) REFERENCES dim_product(ProductSK),

    CONSTRAINT fk_fact_payment
        FOREIGN KEY (PaymentMethodSK) REFERENCES dim_payment_method(PaymentMethodSK),

    INDEX ix_fact_order (OrderID),
    INDEX ix_fact_date (DateSK),
    INDEX ix_fact_customer (CustomerSK)
);


-- ============================================================
-- 5. INSERT INTO DIMENSIONS FROM STAGING
-- ============================================================

-- Customer dimension — initial Type 2 version
INSERT INTO dim_customer
(
    CustomerID, CustomerName, Segment, Region, City, State,
    SignupDate, AgeGroup, EffectiveFrom, EffectiveTo, IsCurrent
)
SELECT
    CustomerID,
    CustomerName,
    Segment,
    Region,
    City,
    State,
    SignupDate,
    AgeGroup,
    COALESCE(SignupDate, '1900-01-01'),
    '9999-12-31',
    TRUE
FROM stg_customers sc
WHERE NOT EXISTS (
    SELECT 1
    FROM dim_customer dc
    WHERE dc.CustomerID = sc.CustomerID
);


-- Product dimension
INSERT INTO dim_product (ProductName, ProductCategory)
SELECT DISTINCT
    Product,
    ProductCategory
FROM stg_orders
WHERE Product IS NOT NULL
  AND ProductCategory IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM dim_product dp
      WHERE dp.ProductName = stg_orders.Product
        AND dp.ProductCategory = stg_orders.ProductCategory
  );


-- Payment method dimension
INSERT INTO dim_payment_method (PaymentMethod)
SELECT DISTINCT
    PaymentMethod
FROM stg_orders
WHERE PaymentMethod IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM dim_payment_method dpm
      WHERE dpm.PaymentMethod = stg_orders.PaymentMethod
  );


-- Date dimension
INSERT INTO dim_date
(
    DateSK, FullDate, Year, Quarter, Month,
    MonthName, Day, DayOfWeek
)
SELECT DISTINCT
    CAST(DATE_FORMAT(OrderDate, '%Y%m%d') AS UNSIGNED) AS DateSK,
    OrderDate AS FullDate,
    YEAR(OrderDate) AS Year,
    QUARTER(OrderDate) AS Quarter,
    MONTH(OrderDate) AS Month,
    MONTHNAME(OrderDate) AS MonthName,
    DAY(OrderDate) AS Day,
    DAYNAME(OrderDate) AS DayOfWeek
FROM stg_orders so
WHERE OrderDate IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM dim_date dd
      WHERE dd.FullDate = so.OrderDate
  );


-- ============================================================
-- 6. LOAD FACT TABLE
-- Only valid customer references are loaded.
-- Orphan orders remain in stg_orphan_orders.
-- ============================================================

INSERT INTO fact_sales
(
    OrderID,
    DateSK,
    CustomerSK,
    ProductSK,
    PaymentMethodSK,
    OrderStatus,
    Quantity,
    Discount,
    Sales,
    Profit
)
SELECT
    so.OrderID,
    dd.DateSK,
    dc.CustomerSK,
    dp.ProductSK,
    dpm.PaymentMethodSK,
    so.OrderStatus,
    so.Quantity,
    so.Discount,
    so.Sales,
    so.Profit
FROM stg_orders so
INNER JOIN dim_date dd
    ON dd.FullDate = so.OrderDate
INNER JOIN dim_customer dc
    ON dc.CustomerID = so.CustomerID
   AND dc.IsCurrent = TRUE
INNER JOIN dim_product dp
    ON dp.ProductName = so.Product
   AND dp.ProductCategory = so.ProductCategory
INNER JOIN dim_payment_method dpm
    ON dpm.PaymentMethod = so.PaymentMethod
WHERE so.CustomerID IS NOT NULL
  AND so.Product IS NOT NULL
  AND so.ProductCategory IS NOT NULL
  AND so.PaymentMethod IS NOT NULL;


-- ============================================================
-- 7. TYPE 2 SCD PATTERN — CUSTOMER REGION CHANGE
-- Example logic:
-- If an existing customer changes Region, close the old row and
-- insert a new current version.
-- ============================================================

/*
-- Example for one customer:

START TRANSACTION;

UPDATE dim_customer
SET
    EffectiveTo = CURRENT_DATE - INTERVAL 1 DAY,
    IsCurrent = FALSE
WHERE CustomerID = 'CUST0001'
  AND IsCurrent = TRUE
  AND Region <> 'West';

INSERT INTO dim_customer
(
    CustomerID, CustomerName, Segment, Region, City, State,
    SignupDate, AgeGroup, EffectiveFrom, EffectiveTo, IsCurrent
)
SELECT
    CustomerID, CustomerName, Segment, 'West', City, State,
    SignupDate, AgeGroup, CURRENT_DATE, '9999-12-31', TRUE
FROM stg_customers
WHERE CustomerID = 'CUST0001';

COMMIT;
*/


-- ============================================================
-- 8. ANALYTICAL QUERY — SALES BY REGION AND PRODUCT CATEGORY
-- Joins fact + customer + product + date.
-- ============================================================

SELECT
    dd.Year,
    dd.MonthName,
    dc.Region,
    dp.ProductCategory,
    SUM(fs.Sales) AS TotalSales,
    SUM(fs.Profit) AS TotalProfit,
    SUM(fs.Quantity) AS TotalQuantity
FROM fact_sales fs
JOIN dim_customer dc
    ON fs.CustomerSK = dc.CustomerSK
JOIN dim_product dp
    ON fs.ProductSK = dp.ProductSK
JOIN dim_date dd
    ON fs.DateSK = dd.DateSK
GROUP BY
    dd.Year,
    dd.Month,
    dd.MonthName,
    dc.Region,
    dp.ProductCategory
ORDER BY
    dd.Year,
    dd.Month,
    TotalSales DESC;


-- ============================================================
-- 9. DATA QUALITY CHECKS
-- ============================================================

-- Check for orphan orders still waiting in staging
SELECT COUNT(*) AS OrphanOrderCount
FROM stg_orphan_orders;

-- Check fact referential integrity
SELECT COUNT(*) AS InvalidCustomerFK
FROM fact_sales fs
LEFT JOIN dim_customer dc
    ON fs.CustomerSK = dc.CustomerSK
WHERE dc.CustomerSK IS NULL;

-- Basic warehouse KPI check
SELECT
    SUM(Sales) AS TotalSales,
    SUM(Profit) AS TotalProfit,
    SUM(Quantity) AS TotalQuantity
FROM fact_sales;
TRUNCATE TABLE fact_sales;