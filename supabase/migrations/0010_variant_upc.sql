-- =============================================================================
-- 0010_variant_upc.sql — unique UPC per variant (AceStock)
--
-- A UPC (stored in variants.barcode) identifies a specific scannable item, so it
-- must be unique across all variants. This enables a scanned/typed UPC to resolve
-- to exactly one variant (groundwork for the home-screen search / scan-to-find
-- feature). Uniqueness is required at the app layer too (the add-variant form
-- requires a UPC); this index makes it a hard guarantee.
--
-- Partial index (where barcode is not null) so legacy variants without a UPC are
-- unaffected.
-- =============================================================================

create unique index if not exists uq_variants_barcode
  on variants (barcode)
  where barcode is not null;
