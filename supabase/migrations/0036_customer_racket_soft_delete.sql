-- =============================================================================
-- 0036_customer_racket_soft_delete.sql — keep stringing history (AceStock, 1A)
--
-- Removing a customer's racket used to DELETE the row, which cascaded to every
-- string job on it (or failed outright once a job had been paid, because the
-- sale line still referenced the job). Rackets are now retired by setting
-- is_active = false, and the database refuses to delete a racket that has
-- string jobs, so history can't be lost by accident.
--
-- A retired racket's tag barcode is freed for reuse: uniqueness and barcode
-- lookup only consider active rackets.
--
-- Re-runnable.
-- =============================================================================

-- 1. A racket with string jobs can no longer be deleted (was: on delete cascade).
alter table string_jobs drop constraint if exists string_jobs_customer_racket_id_fkey;
alter table string_jobs
  add constraint string_jobs_customer_racket_id_fkey
  foreign key (customer_racket_id) references customer_rackets (id) on delete restrict;

-- 2. Tag barcodes are unique among active rackets only.
drop index if exists uq_customer_rackets_barcode;
create unique index if not exists uq_customer_rackets_barcode
  on customer_rackets (barcode)
  where barcode is not null and is_active;

-- 3. resolve_barcode — same as 0032, except a retired racket's tag no longer
--    resolves (so a reused tag finds the new racket, not the old one).
create or replace function resolve_barcode(p_code text)
returns table (
  kind          text,
  code          text,
  id            uuid,      -- the matched thing's id (product / unit / racket / gift card)
  product_id    uuid,      -- for a unit: its catalog product; else null
  customer_id   uuid,
  open_job_id   uuid,
  brand         text,
  name          text,
  attributes    jsonb,
  sell_price    numeric,
  is_serialized boolean,
  unit_status   text       -- for a unit: its status; else null
)
language plpgsql
security invoker
stable
as $$
declare
  v_code       text := regexp_replace(coalesce(p_code, ''), '\s+', '', 'g');
  v_candidates text[];
  v_product    products%rowtype;
  v_unit       product_units%rowtype;
  v_racket     customer_rackets%rowtype;
  v_gift_card  gift_cards%rowtype;
begin
  if v_code = '' then
    return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  -- EAN-13 with a leading zero <-> UPC-A.
  v_candidates := array[v_code];
  if v_code ~ '^0[0-9]{12}$' then
    v_candidates := v_candidates || substr(v_code, 2);
  elsif v_code ~ '^[0-9]{12}$' then
    v_candidates := v_candidates || ('0' || v_code);
  end if;

  -- Product UPC.
  select * into v_product from products p where p.barcode = any (v_candidates) limit 1;
  if found then
    return query select 'product', v_product.barcode, v_product.id, null::uuid, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        v_product.is_serialized, null::text;
    return;
  end if;

  -- Individual unit's personal barcode.
  select * into v_unit from product_units u where u.barcode = any (v_candidates) limit 1;
  if found then
    select * into v_product from products p where p.id = v_unit.product_id;
    return query select 'unit', v_unit.barcode, v_unit.id, v_unit.product_id, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        true, v_unit.status;
    return;
  end if;

  -- Customer racket tag (active rackets only).
  select * into v_racket
  from customer_rackets r
  where r.barcode = any (v_candidates) and r.is_active
  limit 1;
  if found then
    return query select 'racket', v_racket.barcode, v_racket.id, null::uuid, v_racket.customer_id,
                        (select j.id from string_jobs j
                          where j.customer_racket_id = v_racket.id
                            and j.status in ('entered', 'complete')
                          order by j.entered_at desc limit 1),
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  select * into v_gift_card from gift_cards g where g.code = any (v_candidates) limit 1;
  if found then
    return query select 'gift_card', v_gift_card.code, v_gift_card.id, null::uuid, v_gift_card.customer_id, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                      null::text, null::text, null::jsonb, null::numeric, false, null::text;
end;
$$;

grant execute on function resolve_barcode(text) to authenticated;
