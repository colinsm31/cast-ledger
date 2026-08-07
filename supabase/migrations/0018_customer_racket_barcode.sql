-- =============================================================================
-- 0018_customer_racket_barcode.sql — barcode on customer rackets (AceStock)
--
-- Each customer racket now carries a scannable barcode instead of a free-text
-- nickname. Rename the old `label` column to `barcode` and make it uniquely
-- searchable so a scan resolves to exactly one racket (used by the home-screen
-- scan-to-find, which jumps straight into a new string job for that racket).
--
-- Re-runnable.
-- =============================================================================

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'customer_rackets' and column_name = 'label'
  ) and not exists (
    select 1 from information_schema.columns
    where table_name = 'customer_rackets' and column_name = 'barcode'
  ) then
    alter table customer_rackets rename column label to barcode;
  end if;
end $$;

-- A scanned barcode must resolve to one racket (partial: rackets without a
-- barcode are unaffected).
create unique index if not exists uq_customer_rackets_barcode
  on customer_rackets (barcode)
  where barcode is not null;
