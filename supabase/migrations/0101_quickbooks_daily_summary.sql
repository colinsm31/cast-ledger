-- =============================================================================
-- 0101_quickbooks_daily_summary.sql — a daily summary for QuickBooks (AceStock, Phase 4A)
--
-- Adds:
--   1. Settings for the QuickBooks account each figure posts to, with defaults
--      the shop can rename to match its chart of accounts (Settings, admins):
--      cash, card and check takings; gift card and store credit liability;
--      sales tax payable; sales income; stringing income.
--   2. report_daily_summary(from, to, time_zone) — one balanced journal entry
--      per day in [from, to), days counted in the shop's time zone:
--        debits:  what was taken by cash, card and check (less what was given
--                 back that way), and gift cards and store credit spent;
--        credits: sales by category and stringing (less returns), sales tax
--                 (less tax refunded) and gift cards sold.
--      A figure that nets the other way (e.g. more cash refunded than taken)
--      moves to the other column. An exchange's credit is on both its return
--      and its sale, so it nets out and isn't listed. Each line names its
--      account and a memo; lines that net to zero are left out. Each day's
--      debits equal its credits, because each sale's payments equal its lines
--      plus tax, and each refund's likewise.
--   Gift card and store credit changes made outside a sale or refund
--   (adjustments) aren't sales activity and aren't included.
--
-- Admins only; runs with the caller's rights. Re-runnable.
-- =============================================================================

-- 1. Account names --------------------------------------------------------------
alter table settings add column if not exists qb_cash_account         text not null default 'Undeposited Funds';
alter table settings add column if not exists qb_card_account         text not null default 'Undeposited Funds';
alter table settings add column if not exists qb_check_account        text not null default 'Undeposited Funds';
alter table settings add column if not exists qb_gift_card_account    text not null default 'Gift Card Liability';
alter table settings add column if not exists qb_store_credit_account text not null default 'Store Credit Liability';
alter table settings add column if not exists qb_sales_tax_account    text not null default 'Sales Tax Payable';
alter table settings add column if not exists qb_sales_account        text not null default 'Sales';
alter table settings add column if not exists qb_stringing_account    text not null default 'Stringing Income';

alter table settings drop constraint if exists ck_settings_qb_accounts;
alter table settings add constraint ck_settings_qb_accounts check (
  char_length(btrim(qb_cash_account)) between 1 and 100
  and char_length(btrim(qb_card_account)) between 1 and 100
  and char_length(btrim(qb_check_account)) between 1 and 100
  and char_length(btrim(qb_gift_card_account)) between 1 and 100
  and char_length(btrim(qb_store_credit_account)) between 1 and 100
  and char_length(btrim(qb_sales_tax_account)) between 1 and 100
  and char_length(btrim(qb_sales_account)) between 1 and 100
  and char_length(btrim(qb_stringing_account)) between 1 and 100
);

comment on column settings.qb_cash_account is 'QuickBooks account for cash taken (daily summary export, 0101)';
comment on column settings.qb_card_account is 'QuickBooks account for card payments';
comment on column settings.qb_check_account is 'QuickBooks account for checks';
comment on column settings.qb_gift_card_account is 'QuickBooks liability account for gift cards';
comment on column settings.qb_store_credit_account is 'QuickBooks liability account for store credit';
comment on column settings.qb_sales_tax_account is 'QuickBooks sales tax payable account';
comment on column settings.qb_sales_account is 'QuickBooks income account for item sales (memo names the category)';
comment on column settings.qb_stringing_account is 'QuickBooks income account for stringing';

-- 2. report_daily_summary -------------------------------------------------------
drop function if exists report_daily_summary(timestamptz, timestamptz, text);
create or replace function report_daily_summary(p_from timestamptz, p_to timestamptz, p_time_zone text)
returns table (
  day     date,
  line_no integer,
  account text,
  debit   numeric,
  credit  numeric,
  memo    text
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v settings%rowtype;
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);
  if p_time_zone is null or not exists (select 1 from pg_timezone_names where name = p_time_zone) then
    raise exception 'Unknown time zone: %', coalesce(p_time_zone, '(none)')
      using errcode = '22023';
  end if;
  select * into v from settings where id;

  return query
  with s as (
    select x.id, (x.sold_at at time zone p_time_zone)::date as d, x.tax
      from sales x where x.sold_at >= p_from and x.sold_at < p_to
  ),
  r as (
    select x.id, (x.refunded_at at time zone p_time_zone)::date as d, x.tax
      from refunds x where x.refunded_at >= p_from and x.refunded_at < p_to
  ),
  -- Positive amounts are debits, negative credits.
  amounts as (
    select s.d, sp.method as what, sp.amount as amt
      from sale_payments sp join s on s.id = sp.sale_id
     where sp.method <> 'exchange'
    union all
    select r.d, rp.method, -rp.amount
      from refund_payments rp join r on r.id = rp.refund_id
     where rp.method <> 'exchange'
    union all
    select s.d,
           case when sl.gift_card_id is not null then 'gift_card_sold'
                when sl.product_id is null then 'stringing'
                else 'sales:' || coalesce(c.name, '(no category)') end,
           -(sl.qty * sl.unit_price)
      from sale_lines sl join s on s.id = sl.sale_id
      left join products p on p.id = sl.product_id
      left join categories c on c.id = p.category_id
    union all
    select r.d,
           case when sl.gift_card_id is not null then 'gift_card_sold'
                when sl.product_id is null then 'stringing'
                else 'sales:' || coalesce(c.name, '(no category)') end,
           rl.qty * rl.unit_price
      from refund_lines rl join r on r.id = rl.refund_id
      join sale_lines sl on sl.id = rl.sale_line_id
      left join products p on p.id = sl.product_id
      left join categories c on c.id = p.category_id
    union all
    select s.d, 'tax', -s.tax from s
    union all
    select r.d, 'tax', r.tax from r
  ),
  named as (
    select a.d,
           case a.what
             when 'cash'           then v.qb_cash_account
             when 'credit'         then v.qb_card_account
             when 'check'          then v.qb_check_account
             when 'gift_card'      then v.qb_gift_card_account
             when 'gift_card_sold' then v.qb_gift_card_account
             when 'store_credit'   then v.qb_store_credit_account
             when 'tax'            then v.qb_sales_tax_account
             when 'stringing'      then v.qb_stringing_account
             else v.qb_sales_account
           end as acct,
           case a.what
             when 'cash'           then 'Cash'
             when 'credit'         then 'Card'
             when 'check'          then 'Checks'
             when 'gift_card'      then 'Paid by gift card'
             when 'gift_card_sold' then 'Gift cards sold'
             when 'store_credit'   then 'Paid by store credit'
             when 'tax'            then 'Sales tax'
             when 'stringing'      then 'Stringing'
             else 'Sales: ' || substr(a.what, 7)
           end as note,
           case a.what
             when 'cash' then 1 when 'credit' then 2 when 'check' then 3
             when 'gift_card' then 4 when 'store_credit' then 5
             when 'stringing' then 7 when 'gift_card_sold' then 8 when 'tax' then 9
             else 6
           end as ord,
           a.amt
      from amounts a
  ),
  summed as (
    select n.d, n.acct, n.note, min(n.ord) as ord, sum(n.amt) as total
      from named n
     group by n.d, n.acct, n.note
    having sum(n.amt) <> 0
  )
  select x.d,
         (row_number() over (partition by x.d order by x.ord, x.note))::int,
         x.acct,
         case when x.total > 0 then x.total end,
         case when x.total < 0 then -x.total end,
         x.note
    from summed x
   order by x.d, 2;
end;
$$;

revoke all on function report_daily_summary(timestamptz, timestamptz, text) from public, anon;
grant execute on function report_daily_summary(timestamptz, timestamptz, text) to authenticated;
