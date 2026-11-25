-- =============================================================================
-- 0096_report_price_changes.sql — discounts and price changes by who (AceStock, Phase 4A)
--
-- Phase 2 reported how many price changes and discounts there were and their
-- total (sales_summary). The per-person breakdown was left for 4A.
--
-- Adds report_price_changes(from, to): every price change and discount on a
-- sale made in [from, to), one row each, with
--   * kind: 'price_change' (list price to the price charged before discounts),
--     'line_discount' or 'ticket_discount' (a line's share of the ticket's);
--   * made_by: who rang the sale (the person at the register);
--   * approved_by: the admin who approved the ticket's discount, if one did
--     (price changes have no approval);
--   * amount: qty x (from_price - to_price) — what was taken off; negative
--     when a price was raised;
--   * reason: what was typed, or "(none)". Reasons are optional (0093), and a
--     report shows that none was given rather than leaving the row out.
-- The screen totals it per person.
--
-- Admins only; runs with the caller's rights. Re-runnable.
-- =============================================================================

drop function if exists report_price_changes(timestamptz, timestamptz);
create or replace function report_price_changes(p_from timestamptz, p_to timestamptz)
returns table (
  kind        text,
  sold_at     timestamptz,
  sale_id     uuid,
  made_by     text,
  approved_by text,
  item        text,
  qty         integer,
  from_price  numeric,
  to_price    numeric,
  amount      numeric,
  reason      text
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);

  return query
  with lines as (
    select s.id as sid, s.sold_at as at, s.ticket_discount_reason,
           coalesce(maker.email, '(not recorded)') as maker,
           approver.email as approver,
           sl.id as line_id, sl.qty as n, sl.unit_price, sl.list_price, sl.price_reason, sl.discount_reason,
           coalesce(sl.price_before_discount, sl.unit_price) as before_discount,
           coalesce(sl.line_discount_each, 0) as line_each,
           coalesce(sl.ticket_discount_each, 0) as ticket_each,
           case
             when sl.product_id is not null then trim(coalesce(p.brand, '') || ' ' || p.name)
             when sl.string_job_id is not null then 'Stringing'
             else 'Gift card'
           end as item_name
      from sales s
      join sale_lines sl on sl.sale_id = s.id
      left join products p on p.id = sl.product_id
      left join profiles maker on maker.id = s.user_id
      left join profiles approver on approver.id = s.discount_approved_by
     where s.sold_at >= p_from and s.sold_at < p_to
  ),
  changes as (
    select 'price_change'::text as k, 1 as ord, l.*, l.list_price as was, l.before_discount as now_price,
           l.price_reason as why, null::text as ok_by
      from lines l
     where l.list_price is not null and l.before_discount <> l.list_price
    union all
    select 'line_discount', 2, l.*, l.before_discount, l.before_discount - l.line_each,
           l.discount_reason, l.approver
      from lines l
     where l.line_each > 0
    union all
    select 'ticket_discount', 3, l.*, l.before_discount - l.line_each, l.unit_price,
           l.ticket_discount_reason, l.approver
      from lines l
     where l.ticket_each > 0
  )
  select c.k, c.at, c.sid, c.maker, c.ok_by, c.item_name, c.n, c.was, c.now_price,
         c.n * (c.was - c.now_price),
         coalesce(nullif(trim(c.why), ''), '(none)')
    from changes c
   order by c.at, c.sid, c.item_name, c.line_id, c.ord;
end;
$$;

revoke all on function report_price_changes(timestamptz, timestamptz) from public, anon;
grant execute on function report_price_changes(timestamptz, timestamptz) to authenticated;
