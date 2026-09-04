-- =============================================================================
-- 0031_resolve_barcode.sql — one-shot barcode resolution (AceStock)
--
-- A scanned code may be an inventory product, a customer's racket, or a gift
-- card. The home screen and the POS each used to run their own chain of
-- queries to work that out; this RPC is the single definition of "what does
-- this barcode mean" so both screens (and later the iOS app) share it.
--
-- Resolution order: product → customer racket → gift card → none.
--
-- Normalization: whitespace is stripped. A 13-digit EAN that starts with a
-- zero is the same item as its 12-digit UPC-A form (scanners set to EAN mode
-- emit the leading zero), so both forms are tried against every barcode
-- column. Codes are otherwise matched exactly (gift-card and racket codes may
-- be alphanumeric).
--
-- Returns exactly one row. `kind` is one of 'product' | 'racket' |
-- 'gift_card' | 'none'. Product columns are filled for products so the POS can
-- add the line without a second round-trip; racket rows carry the owning
-- customer and the racket's open string job (entered/complete), if any.
--
-- Security invoker: it only reads tables the caller can already read, so the
-- existing RLS policies apply unchanged.
--
-- Re-runnable.
-- =============================================================================

create or replace function resolve_barcode(p_code text)
returns table (
  kind         text,
  code         text,
  id           uuid,
  customer_id  uuid,
  open_job_id  uuid,
  brand        text,
  name         text,
  attributes   jsonb,
  sell_price   numeric
)
language plpgsql
security invoker
stable
as $$
declare
  v_code       text := regexp_replace(coalesce(p_code, ''), '\s+', '', 'g');
  v_candidates text[];
  v_product    products%rowtype;
  v_racket     customer_rackets%rowtype;
  v_gift_card  gift_cards%rowtype;
begin
  if v_code = '' then
    return query select 'none', v_code, null::uuid, null::uuid, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric;
    return;
  end if;

  -- EAN-13 with a leading zero <-> UPC-A.
  v_candidates := array[v_code];
  if v_code ~ '^0[0-9]{12}$' then
    v_candidates := v_candidates || substr(v_code, 2);
  elsif v_code ~ '^[0-9]{12}$' then
    v_candidates := v_candidates || ('0' || v_code);
  end if;

  select * into v_product
  from products p
  where p.barcode = any (v_candidates)
  limit 1;
  if found then
    return query select 'product', v_product.barcode, v_product.id, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price;
    return;
  end if;

  select * into v_racket
  from customer_rackets r
  where r.barcode = any (v_candidates)
  limit 1;
  if found then
    return query select 'racket', v_racket.barcode, v_racket.id, v_racket.customer_id,
                        (select j.id
                         from string_jobs j
                         where j.customer_racket_id = v_racket.id
                           and j.status in ('entered', 'complete')
                         order by j.entered_at desc
                         limit 1),
                        null::text, null::text, null::jsonb, null::numeric;
    return;
  end if;

  select * into v_gift_card
  from gift_cards g
  where g.code = any (v_candidates)
  limit 1;
  if found then
    return query select 'gift_card', v_gift_card.code, v_gift_card.id, v_gift_card.customer_id, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric;
    return;
  end if;

  return query select 'none', v_code, null::uuid, null::uuid, null::uuid,
                      null::text, null::text, null::jsonb, null::numeric;
end;
$$;

grant execute on function resolve_barcode(text) to authenticated;
