-- =============================================================================
-- 0050_real_numbers.sql — amounts and quantities must be real numbers
--                         (AceStock, polish review #1)
--
-- Before:
--   • Postgres numbers can be NaN ("not a number"), and NaN = NaN, so the
--     require_cents and require_half_units checks let it through. A NaN stock
--     quantity or gift card amount was stored for good, and every total built
--     on it (stock on hand, card balance) became NaN too.
--   • Infinity also passed the checks (the columns then refused it with a
--     raw error).
--
-- Now:
--   1. require_cents and require_half_units refuse NaN and infinity with a
--      message naming the field. Every function that takes an amount or a
--      quantity already calls one of them (0046, 0049).
--   2. Every stored number column refuses NaN, so direct table saves (a
--      product's price, a string job's tension) are covered too. Infinity
--      can't be stored in these columns at all.
--
-- AceStock-Test had no NaN values when this was written. Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. The amount and quantity checks.
-- ----------------------------------------------------------------------------
-- require_cents — same as 0046, plus: a real number.
create or replace function require_cents(p_amount numeric, p_label text)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_amount in ('NaN', 'Infinity', '-Infinity') then
    raise exception '% must be a number (got %)', p_label, p_amount;
  end if;
  if p_amount is not null and p_amount <> round(p_amount, 2) then
    raise exception '% % has more than 2 decimal places', p_label, trim_scale(p_amount);
  end if;
end;
$$;

-- require_half_units — same as 0049, plus: a real number.
create or replace function require_half_units(p_qty numeric, p_label text)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_qty in ('NaN', 'Infinity', '-Infinity') then
    raise exception '% must be a number (got %)', p_label, p_qty;
  end if;
  if p_qty is not null and p_qty * 2 <> trunc(p_qty * 2) then
    raise exception '% % must be a whole number or a half, like 2 or 2.5', p_label, trim_scale(p_qty);
  end if;
end;
$$;

revoke all on function require_cents(numeric, text) from public, anon, authenticated;
revoke all on function require_half_units(numeric, text) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. No NaN in any stored number.
-- ----------------------------------------------------------------------------
alter table gift_card_txns drop constraint if exists ck_gift_card_txns_amount_number;
alter table gift_card_txns add constraint ck_gift_card_txns_amount_number check (amount <> 'NaN');
alter table inventory_txns drop constraint if exists ck_inventory_txns_qty_number;
alter table inventory_txns add constraint ck_inventory_txns_qty_number check (qty <> 'NaN');
alter table inventory_txns drop constraint if exists ck_inventory_txns_unit_cost_number;
alter table inventory_txns add constraint ck_inventory_txns_unit_cost_number check (unit_cost <> 'NaN');
alter table products drop constraint if exists ck_products_cost_number;
alter table products add constraint ck_products_cost_number check (cost <> 'NaN');
alter table products drop constraint if exists ck_products_sell_price_number;
alter table products add constraint ck_products_sell_price_number check (sell_price <> 'NaN');
alter table refund_lines drop constraint if exists ck_refund_lines_unit_price_number;
alter table refund_lines add constraint ck_refund_lines_unit_price_number check (unit_price <> 'NaN');
alter table refund_payments drop constraint if exists ck_refund_payments_amount_number;
alter table refund_payments add constraint ck_refund_payments_amount_number check (amount <> 'NaN');
alter table refunds drop constraint if exists ck_refunds_subtotal_number;
alter table refunds add constraint ck_refunds_subtotal_number check (subtotal <> 'NaN');
alter table refunds drop constraint if exists ck_refunds_tax_number;
alter table refunds add constraint ck_refunds_tax_number check (tax <> 'NaN');
alter table sale_lines drop constraint if exists ck_sale_lines_unit_price_number;
alter table sale_lines add constraint ck_sale_lines_unit_price_number check (unit_price <> 'NaN');
alter table sale_payments drop constraint if exists ck_sale_payments_amount_number;
alter table sale_payments add constraint ck_sale_payments_amount_number check (amount <> 'NaN');
alter table sales drop constraint if exists ck_sales_subtotal_number;
alter table sales add constraint ck_sales_subtotal_number check (subtotal <> 'NaN');
alter table sales drop constraint if exists ck_sales_tax_number;
alter table sales add constraint ck_sales_tax_number check (tax <> 'NaN');
alter table sales drop constraint if exists ck_sales_tax_rate_number;
alter table sales add constraint ck_sales_tax_rate_number check (tax_rate <> 'NaN');
alter table settings drop constraint if exists ck_settings_stringing_labor_number;
alter table settings add constraint ck_settings_stringing_labor_number check (stringing_labor <> 'NaN');
alter table settings drop constraint if exists ck_settings_tax_rate_number;
alter table settings add constraint ck_settings_tax_rate_number check (tax_rate <> 'NaN');
alter table store_credit_txns drop constraint if exists ck_store_credit_txns_amount_number;
alter table store_credit_txns add constraint ck_store_credit_txns_amount_number check (amount <> 'NaN');
alter table string_jobs drop constraint if exists ck_string_jobs_cross_tension_number;
alter table string_jobs add constraint ck_string_jobs_cross_tension_number check (cross_tension <> 'NaN');
alter table string_jobs drop constraint if exists ck_string_jobs_main_tension_number;
alter table string_jobs add constraint ck_string_jobs_main_tension_number check (main_tension <> 'NaN');
alter table string_jobs drop constraint if exists ck_string_jobs_price_number;
alter table string_jobs add constraint ck_string_jobs_price_number check (price <> 'NaN');
alter table string_jobs drop constraint if exists ck_string_jobs_strings_price_number;
alter table string_jobs add constraint ck_string_jobs_strings_price_number check (strings_price <> 'NaN');
