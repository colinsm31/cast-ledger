-- =============================================================================
-- 0044_staff_only_helpers.sql — owner-rights helpers are staff-only
--                               (AceStock, commit 2c)
--
-- 0043 added four helper functions that run with owner rights (so row-level
-- security doesn't apply inside them) and were callable by any signed-in
-- account, including one still waiting for approval:
--   • sale_refund_tax, sale_refundable_by_method, refund_method_overages —
--     given a sale's id, they reveal what it took by payment type and its tax;
--   • string_job_strings_price — a pair of strings' price.
-- They change nothing, but "only approved staff can read the shop's data"
-- (0041) should hold for every function.
--
-- Now:
--   1. The three refund helpers can't be called from the app or API at all.
--      They're only used inside record_refund, string_change_quote and
--      change_paid_string_job, which run with owner rights and still can.
--   2. string_job_strings_price stays callable (the job-entry trigger, which
--      runs as the signed-in user, needs it) but starts with require_staff().
--
-- The rule from here on (see supabase/README.md): an owner-rights function is
-- either granted to signed-in users and calls require_staff() (or only writes,
-- which the 0041 trigger refuses for non-staff), or isn't granted at all.
--
-- No data changes. Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Internal refund helpers: not callable from the app or API.
-- ----------------------------------------------------------------------------
revoke all on function sale_refund_tax(uuid, numeric, uuid)    from public, anon, authenticated;
revoke all on function sale_refundable_by_method(uuid, uuid)   from public, anon, authenticated;
revoke all on function refund_method_overages(uuid, uuid)      from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. string_job_strings_price — same as 0043, plus: staff only.
-- ----------------------------------------------------------------------------
create or replace function string_job_strings_price(p_main_product_id uuid, p_cross_product_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform require_staff();

  return round(
           coalesce((select stringing_labor from settings where id), 0)
         + coalesce((select sum(coalesce(p.sell_price, 0))
                       from products p
                      where p.id in (select distinct x
                                       from (values (p_main_product_id), (p_cross_product_id)) t(x)
                                      where x is not null)), 0),
         2);
end;
$$;

revoke all on function string_job_strings_price(uuid, uuid) from public, anon;
grant execute on function string_job_strings_price(uuid, uuid) to authenticated;
