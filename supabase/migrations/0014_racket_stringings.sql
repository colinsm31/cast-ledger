-- =============================================================================
-- 0014_racket_stringings.sql — restringing events for a customer's racket
--
-- Records each time a customer's racket is strung: the string used (optionally a
-- catalog string variant so it can be deducted from stock), tension(s), price
-- charged, who strung it, and when. These rows are also the re-stringing history
-- (to be surfaced on the customer screen later).
-- =============================================================================

create table racket_stringings (
  id                 uuid primary key default gen_random_uuid(),
  customer_racket_id uuid not null references customer_rackets (id) on delete cascade,
  string_variant_id  uuid references variants (id),   -- optional: catalog string used
  string_label       text,                            -- string name (denormalized / free-form)
  tension_main       numeric(5, 1) check (tension_main > 0),
  tension_cross      numeric(5, 1) check (tension_cross > 0),   -- for hybrids / different cross
  price              numeric(12, 2) check (price >= 0),
  strung_by          text,
  strung_at          timestamptz not null default now(),
  notes              text,
  created_at         timestamptz not null default now()
);
create index idx_racket_stringings_racket on racket_stringings (customer_racket_id);
create index idx_racket_stringings_variant on racket_stringings (string_variant_id);

-- RLS + grants
alter table racket_stringings enable row level security;
create policy racket_stringings_authenticated_all
  on racket_stringings for all to authenticated using (true) with check (true);
grant select, insert, update, delete on racket_stringings to authenticated;

-- -----------------------------------------------------------------------------
-- record_stringing — record a restring; if p_deduct_stock and a catalog string
-- variant is given, atomically post an adjust -1 inventory_txn (one set used).
-- Returns the new stringing id.
-- -----------------------------------------------------------------------------
create or replace function record_stringing(
  p_customer_racket_id uuid,
  p_string_variant_id  uuid,
  p_string_label       text,
  p_tension_main       numeric,
  p_tension_cross      numeric,
  p_price              numeric,
  p_strung_by          text,
  p_deduct_stock       boolean,
  p_notes              text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if not exists (select 1 from customer_rackets where id = p_customer_racket_id) then
    raise exception 'Unknown customer_racket_id %', p_customer_racket_id;
  end if;

  insert into racket_stringings (
    id, customer_racket_id, string_variant_id, string_label,
    tension_main, tension_cross, price, strung_by, notes
  )
  values (
    v_id, p_customer_racket_id, p_string_variant_id, nullif(trim(p_string_label), ''),
    p_tension_main, p_tension_cross, p_price, nullif(trim(p_strung_by), ''),
    nullif(trim(p_notes), '')
  );

  -- Optionally consume one set of the chosen catalog string from stock.
  if coalesce(p_deduct_stock, false) and p_string_variant_id is not null then
    if not exists (select 1 from variants where id = p_string_variant_id) then
      raise exception 'Unknown string_variant_id %', p_string_variant_id;
    end if;
    insert into inventory_txns (txn_type, variant_id, qty, note)
    values ('adjust', p_string_variant_id, -1, 'restring');
  end if;

  return v_id;
end;
$$;

grant execute on function
  record_stringing(uuid, uuid, text, numeric, numeric, numeric, text, boolean, text)
  to authenticated;
