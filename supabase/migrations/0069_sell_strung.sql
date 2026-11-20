-- =============================================================================
-- 0069_sell_strung.sql — a racquet sold to a customer becomes one of their
-- racquets (AceStock, Phase 3B)
--
-- Before:
--   • Selling a frame to a customer didn't add it to their racquets, so
--     stringing it in the same visit meant adding it by hand first, and its
--     barcode couldn't be its tag (a unit's barcode was taken).
--
-- Now:
--   1. customer_rackets.product_unit_id: the frame a customer's racquet came
--      from (at most one active racquet per frame).
--   2. add_sold_racket (trigger on product_units): when a frame is sold to a
--      customer, it's added to their racquets with its brand, model, grip and
--      barcode as the tag. If that barcode is already used by something else,
--      the racquet is added without one. A sale to nobody adds nothing.
--   3. barcode_owner: a racquet may share the barcode of the frame it came
--      from, and that frame may keep it; everything else is as 0045, except
--      that leaving out the row being written (p_id) is null-safe, so a check
--      for a row not yet written (p_id null) sees every owner. The
--      three-argument form stays for its callers.
--   4. guard_unique_barcode: as 0045, passing a racquet's frame along.
--   5. resolve_barcode: as 0066, except that a sold frame with a racquet made
--      from it resolves as that racquet (kind 'racket', with its open job),
--      so scanning it starts or opens the customer's string job.
--
-- Re-runnable.
-- =============================================================================

alter table customer_rackets add column if not exists product_unit_id uuid references product_units (id);
comment on column customer_rackets.product_unit_id is 'The frame this racquet came from, when it was bought here';
create unique index if not exists uq_customer_rackets_unit
  on customer_rackets (product_unit_id) where is_active and product_unit_id is not null;

-- -----------------------------------------------------------------------------
-- barcode_owner — same as 0045, plus a racquet and its own frame share a code
-- -----------------------------------------------------------------------------
create or replace function barcode_owner(p_code text, p_table text, p_id uuid, p_own_unit uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_canon text := barcode_canonical(p_code);
  v_owner text;
begin
  select 'the UPC of ' || trim(coalesce(p.brand || ' ', '') || p.name) into v_owner
    from products p
   where p.barcode is not null and barcode_canonical(p.barcode) = v_canon
     and not (p_table = 'products' and p.id is not distinct from p_id)
   limit 1;
  if v_owner is not null then return v_owner; end if;

  -- A racquet may carry the barcode of the frame it came from (p_own_unit).
  select 'the barcode of a ' || trim(coalesce(p.brand || ' ', '') || p.name) || ' unit' into v_owner
    from product_units u join products p on p.id = u.product_id
   where u.barcode is not null and barcode_canonical(u.barcode) = v_canon
     and not (p_table = 'product_units' and u.id is not distinct from p_id)
     and u.id is distinct from p_own_unit
   limit 1;
  if v_owner is not null then return v_owner; end if;

  -- ... and a frame may keep the barcode its own racquet carries.
  select 'the tag on ' || c.first_name || ' ' || c.last_name || '''s '
         || trim(coalesce(r.brand || ' ', '') || r.model) into v_owner
    from customer_rackets r join customers c on c.id = r.customer_id
   where r.is_active and r.barcode is not null and barcode_canonical(r.barcode) = v_canon
     and not (p_table = 'customer_rackets' and r.id is not distinct from p_id)
     and not (p_table = 'product_units' and r.product_unit_id is not distinct from p_id)
   limit 1;
  if v_owner is not null then return v_owner; end if;

  if p_table <> 'gift_cards' then
    select 'a gift card''s code' into v_owner
      from gift_cards g
     where barcode_canonical(g.code) = v_canon
     limit 1;
  end if;
  return v_owner;
end;
$$;

create or replace function barcode_owner(p_code text, p_table text, p_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select barcode_owner(p_code, p_table, p_id, null::uuid);
$$;

revoke all on function barcode_owner(text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function barcode_owner(text, text, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- guard_unique_barcode — same as 0045, passing a racquet's own frame along
-- -----------------------------------------------------------------------------
create or replace function guard_unique_barcode()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   jsonb := to_jsonb(new);  -- the four tables name the column differently
  v_code  text;
  v_owner text;
begin
  v_code := v_row ->> case tg_table_name when 'gift_cards' then 'code' else 'barcode' end;
  if v_code is null or btrim(v_code) = '' then
    return new;
  end if;
  -- A retired racquet's tag is free to reuse.
  if tg_table_name = 'customer_rackets' and not (v_row ->> 'is_active')::boolean then
    return new;
  end if;

  -- Two registers claiming the same code wait for each other here.
  perform pg_advisory_xact_lock(hashtext('acestock.barcode:' || barcode_canonical(v_code)));

  v_owner := barcode_owner(v_code, tg_table_name, new.id,
                           case when tg_table_name = 'customer_rackets' then (v_row ->> 'product_unit_id')::uuid end);
  if v_owner is not null then
    raise exception 'Barcode % is already %', v_code, v_owner;
  end if;
  return new;
end;
$$;

revoke all on function guard_unique_barcode() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- add_sold_racket — a frame sold to a customer joins their racquets
-- -----------------------------------------------------------------------------
create or replace function add_sold_racket()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product products%rowtype;
  v_tag     text := new.barcode;
begin
  if new.status <> 'sold' or old.status = 'sold' or new.customer_id is null then
    return new;
  end if;
  if exists (select 1 from customer_rackets where product_unit_id = new.id and is_active) then
    return new;
  end if;

  select * into v_product from products where id = new.product_id;
  -- Never let a taken code stop the sale: add the racquet without a tag.
  if v_tag is not null then
    perform pg_advisory_xact_lock(hashtext('acestock.barcode:' || barcode_canonical(v_tag)));
    if barcode_owner(v_tag, 'customer_rackets', null, new.id) is not null then
      v_tag := null;
    end if;
  end if;

  insert into customer_rackets (customer_id, product_id, product_unit_id, brand, model, grip_size, barcode)
  values (new.customer_id, new.product_id, new.id, v_product.brand, v_product.name,
          nullif(v_product.attributes ->> 'grip_size', ''), v_tag);
  return new;
end;
$$;

revoke all on function add_sold_racket() from public, anon, authenticated;

drop trigger if exists trg_add_sold_racket on product_units;
create trigger trg_add_sold_racket
  after update of status on product_units
  for each row execute function add_sold_racket();

-- -----------------------------------------------------------------------------
-- resolve_barcode — same as 0066, plus a sold frame resolves as its racquet
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
    -- A frame sold to a customer is their racquet now: its barcode is the tag.
    if v_unit.status = 'sold' then
      select * into v_racket from customer_rackets r
       where r.product_unit_id = v_unit.id and r.is_active
       limit 1;
      if found then
        return query select 'racket', v_unit.barcode, v_racket.id, null::uuid, v_racket.customer_id,
                            (select j.id from string_jobs j
                              where j.customer_racket_id = v_racket.id
                                and j.status in ('entered', 'complete')
                              order by j.entered_at desc limit 1),
                            null::text, null::text, null::jsonb, null::numeric, false, null::text;
        return;
      end if;
    end if;
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
