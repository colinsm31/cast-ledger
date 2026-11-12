-- =============================================================================
-- 0057_discount_rounding.sql — a dollar ticket discount's shares round exactly
-- (AceStock, Phase 2B)
--
-- Before (0056):
--   • sale_totals shared a dollar ticket discount by first working out the
--     discount as a fraction of the items (rounded to Postgres's division
--     precision), then multiplying each item's price by it. When an item's
--     exact share was a half cent, the trimmed fraction left it a hair under
--     the half, so it rounded down: 2 × $82.11 with $7.77 off took $3.88 off
--     each instead of $3.885 → $3.89.
--
-- Now:
--   • Each share is price × discount ÷ items, multiplied first, so it's exact
--     to well past the cent and a half cent rounds up, the same as the
--     register works it out.
--
-- Only sale_totals changes (carried over from 0056). quote_sale and
-- record_sale call it, so both pick up the fix. Re-runnable.
-- =============================================================================

create or replace function sale_totals(p_lines jsonb, p_ticket jsonb default null)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_rate        numeric;
  v_tax_string  boolean;
  v_cap         numeric;
  v_line        jsonb;
  v_qty         integer;
  v_price       numeric;
  v_line_each   numeric;
  v_ticket_each numeric;
  v_unit        numeric;
  v_line_total  numeric;
  v_taxed       boolean;
  v_list        numeric;
  v_changed     boolean;
  v_eligible    boolean;
  v_base        numeric;
  v_percent     numeric;
  v_ticket      numeric := nullif(nullif(p_ticket->>'discount', '')::numeric, 0);
  v_ticket_dollars boolean := false;
  v_after_line  numeric := 0;
  v_lines       jsonb := '[]'::jsonb;
  v_subtotal    numeric := 0;
  v_taxable     numeric := 0;
  v_discounts   numeric := 0;
  v_max_percent numeric := 0;
  v_tax         numeric;
begin
  select tax_rate, tax_stringing, staff_discount_cap into v_rate, v_tax_string, v_cap from settings where id = true;
  v_rate       := coalesce(v_rate, 0);
  v_tax_string := coalesce(v_tax_string, false);

  -- What the eligible items cost after their line discounts: the base a
  -- dollar ticket discount is spread over.
  for v_line in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    if nullif(v_line->>'gift_card_id', '') is null then
      v_price := (v_line->>'unit_price')::numeric;
      v_after_line := v_after_line
        + (v_line->>'qty')::integer * (v_price - discount_each(v_price, nullif(v_line->>'discount', '')::numeric));
    elsif coalesce(nullif(v_line->>'discount', '')::numeric, 0) <> 0 then
      raise exception 'A gift card sale can''t be discounted';
    end if;
  end loop;

  if v_ticket is not null and v_ticket > 1 then
    if v_ticket <> round(v_ticket, 2) then
      raise exception 'A dollar discount must be in whole cents';
    end if;
    if v_ticket > v_after_line then
      raise exception 'A $% ticket discount is more than the $% of items it applies to',
        to_char(v_ticket, 'FM999999990.00'), to_char(v_after_line, 'FM999999990.00');
    end if;
    v_ticket_dollars := true;
  elsif v_ticket is not null and v_ticket < 0 then
    raise exception 'A discount can''t be negative';
  end if;

  for v_line in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality order by ordinality
  loop
    v_qty      := (v_line->>'qty')::integer;
    v_price    := (v_line->>'unit_price')::numeric;
    v_eligible := nullif(v_line->>'gift_card_id', '') is null;
    v_line_each   := 0;
    v_ticket_each := 0;
    if v_eligible then
      v_line_each := discount_each(v_price, nullif(v_line->>'discount', '')::numeric);
      v_ticket_each := case
        when v_ticket is null then 0
        -- Multiply before dividing, so an exact half cent rounds up as it should.
        when v_ticket_dollars then round((v_price - v_line_each) * v_ticket / v_after_line, 2)
        else discount_each(v_price - v_line_each, v_ticket)
      end;
    end if;
    v_unit       := v_price - v_line_each - v_ticket_each;
    v_line_total := v_qty * v_unit;
    v_taxed := case
      when nullif(v_line->>'product_id', '') is not null then true
      when nullif(v_line->>'string_job_id', '') is not null then v_tax_string
      else false
    end;
    v_list := case
      when nullif(v_line->>'product_id', '') is not null then
        (select sell_price from products where id = nullif(v_line->>'product_id', '')::uuid)
      when nullif(v_line->>'string_job_id', '') is not null then
        (select price from string_jobs where id = nullif(v_line->>'string_job_id', '')::uuid)
    end;
    v_changed := v_list is not null and v_price <> v_list;
    v_base    := coalesce(v_list, v_price);
    v_percent := case when v_base > 0 then greatest(0, round((v_base - v_unit) / v_base * 100, 2)) else 0 end;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_total',            v_line_total,
      'taxable',               v_taxed,
      'list_price',            v_list,
      'price_changed',         v_changed,
      'price_reason',          case when v_changed then nullif(trim(v_line->>'price_reason'), '') end,
      'price_before_discount', v_price,
      'line_discount_each',    v_line_each,
      'ticket_discount_each',  v_ticket_each,
      'unit_price',            v_unit,
      'discount_reason',       case when v_line_each > 0 then nullif(trim(v_line->>'discount_reason'), '') end,
      'discount_percent',      v_percent));
    v_subtotal    := v_subtotal + v_line_total;
    v_discounts   := v_discounts + v_qty * (v_line_each + v_ticket_each);
    v_max_percent := greatest(v_max_percent, v_percent);
    if v_taxed then v_taxable := v_taxable + v_line_total; end if;
  end loop;

  v_tax := round(v_taxable * v_rate / 100.0, 2);
  return jsonb_build_object(
    'lines',                  v_lines,
    'subtotal',               v_subtotal,
    'taxable',                v_taxable,
    'tax_rate',               v_rate,
    'tax',                    v_tax,
    'total',                  v_subtotal + v_tax,
    'discount_total',         v_discounts,
    'ticket_discount_reason', case when v_ticket is not null then nullif(trim(p_ticket->>'discount_reason'), '') end,
    'max_discount_percent',   v_max_percent,
    'staff_discount_cap',     coalesce(v_cap, 100)
  );
end;
$$;

revoke all on function sale_totals(jsonb, jsonb) from public, anon, authenticated;
