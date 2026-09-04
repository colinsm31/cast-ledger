-- =============================================================================
-- 0034_product_units_barcode_nullable.sql — make the unit barcode optional
--
-- product_units.barcode is optional (a racket may be received before its
-- personal barcode is assigned). Earlier copies of 0032 created the column as
-- NOT NULL; this brings any such database in line: drop NOT NULL and ensure the
-- uniqueness constraint only applies when a barcode is present.
--
-- Re-runnable.
-- =============================================================================

alter table product_units alter column barcode drop not null;

drop index if exists uq_product_units_barcode;
create unique index if not exists uq_product_units_barcode
  on product_units (barcode) where barcode is not null;
