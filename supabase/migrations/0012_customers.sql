-- =============================================================================
-- 0012_customers.sql — customers + link sales to a customer (AceStock)
--
-- Lets a sale be recorded under a customer and builds purchase history
-- (customer → sales → sale_lines → variants → products). Walk-in sales leave
-- customer_id null.
--
-- Re-runnable: drops and recreates the customers table + sales.customer_id, so
-- applying it again is safe (any existing customer_id links are reset).
-- =============================================================================

-- Idempotent reset (safe to re-run; removes the column's FK dependency first).
alter table sales drop column if exists customer_id;
drop table if exists customers cascade;

create table customers (
  id            uuid primary key default gen_random_uuid(),
  first_name    text not null,
  last_name     text not null,
  phone_number  text,
  email         text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_customers_last_first on customers (lower(last_name), lower(first_name));

create trigger trg_customers_updated_at
  before update on customers
  for each row execute function set_updated_at();

-- Link sales to an optional customer.
alter table sales
  add column customer_id uuid references customers (id);
create index idx_sales_customer on sales (customer_id);

-- -----------------------------------------------------------------------------
-- RLS + grants
-- -----------------------------------------------------------------------------
alter table customers enable row level security;
create policy customers_authenticated_all
  on customers for all to authenticated using (true) with check (true);
grant select, insert, update, delete on customers to authenticated;

-- -----------------------------------------------------------------------------
-- record_sale — accepts an optional customer_id. Atomic: sale header (+ customer)
-- + lines + one sell inventory_txn per line.
-- -----------------------------------------------------------------------------
drop function if exists record_sale(jsonb, text);
drop function if exists record_sale(jsonb, uuid, text);

create or replace function record_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_note        text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_sale_id   uuid := gen_random_uuid();
  v_line      jsonb;
  v_variant   uuid;
  v_qty       integer;
  v_price     numeric;
  v_subtotal  numeric := 0;
begin
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  insert into sales (id, customer_id, subtotal, note)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_variant := (v_line->>'variant_id')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_variant is null or not exists (select 1 from variants where id = v_variant) then
      raise exception 'Unknown variant_id % in sale line', v_variant;
    end if;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;

    insert into sale_lines (sale_id, variant_id, qty, unit_price)
    values (v_sale_id, v_variant, v_qty, v_price);

    insert into inventory_txns (txn_type, variant_id, qty, sale_id)
    values ('sell', v_variant, -v_qty, v_sale_id);

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  update sales set subtotal = v_subtotal where id = v_sale_id;
  return v_sale_id;
end;
$$;

grant execute on function record_sale(jsonb, uuid, text) to authenticated;
