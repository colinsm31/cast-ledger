-- =============================================================================
-- 0066_string_job_numbers.sql — a number for every string job, and scanning
-- its tag (AceStock, Phase 3A)
--
-- Before:
--   • A string job had no number of its own: staff found it through the
--     customer or the racquet's tag, and nothing printed could name it.
--
-- Now:
--   1. string_jobs.job_number: a short number, given in order from 1001
--      (existing jobs are numbered too). It's printed on the job's tag as the
--      barcode "J1042" and can't be set or changed by anyone.
--   2. resolve_barcode: as 0045, plus a job tag ("J1042", any case) resolves
--      to kind 'job' with the job, its customer and (as open_job_id) the job
--      itself. Every other barcode is looked up first, so an existing code
--      that happens to look like a job number still finds what it did.
--
-- Re-runnable.
-- =============================================================================

alter table string_jobs add column if not exists job_number bigint generated always as identity (start with 1001);
create unique index if not exists uq_string_jobs_job_number on string_jobs (job_number);
comment on column string_jobs.job_number is 'The job''s number, printed on its tag as J<number>';

-- -----------------------------------------------------------------------------
-- resolve_barcode — same as 0045, plus job tags
-- -----------------------------------------------------------------------------
create or replace function resolve_barcode(p_code text)
returns table (
  kind          text,
  code          text,
  id            uuid,      -- the matched thing's id (product / unit / racket / gift card / job)
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
set search_path = public, pg_temp
as $$
declare
  v_code       text := regexp_replace(coalesce(p_code, ''), '\s+', '', 'g');
  v_candidates text[];
  v_product    products%rowtype;
  v_unit       product_units%rowtype;
  v_racket     customer_rackets%rowtype;
  v_gift_card  gift_cards%rowtype;
  v_job_id     uuid;
  v_job_number bigint;
  v_customer   uuid;
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
  select * into v_product from products p where p.barcode = any (v_candidates)
   order by (p.barcode = v_code) desc limit 1;
  if found then
    return query select 'product', v_product.barcode, v_product.id, null::uuid, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        v_product.is_serialized, null::text;
    return;
  end if;

  -- Individual unit's personal barcode.
  select * into v_unit from product_units u where u.barcode = any (v_candidates)
   order by (u.barcode = v_code) desc limit 1;
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
  order by (r.barcode = v_code) desc
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

  select * into v_gift_card from gift_cards g where g.code = any (v_candidates)
   order by (g.code = v_code) desc limit 1;
  if found then
    return query select 'gift_card', v_gift_card.code, v_gift_card.id, null::uuid, v_gift_card.customer_id, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  -- A string job's tag: J and its number.
  if v_code ~* '^J[0-9]{1,15}$' then
    select j.id, j.job_number, r.customer_id into v_job_id, v_job_number, v_customer
      from string_jobs j
      join customer_rackets r on r.id = j.customer_racket_id
     where j.job_number = substr(v_code, 2)::bigint;
    if found then
      return query select 'job', 'J' || v_job_number, v_job_id, null::uuid, v_customer, v_job_id,
                          null::text, null::text, null::jsonb, null::numeric, false, null::text;
      return;
    end if;
  end if;

  return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                      null::text, null::text, null::jsonb, null::numeric, false, null::text;
end;
$$;

revoke all on function resolve_barcode(text) from public, anon;
grant execute on function resolve_barcode(text) to authenticated;
