-- =============================================================================
-- 0022_string_job_payment.sql — sell/charge for stringing (AceStock)
--
-- A string job's charge is rung up through the POS like a service line: a sale
-- line may reference either an inventory product (decrements stock) OR a string
-- job (no stock movement). Paying for a job stamps string_jobs.paid_sale_id so
-- we know it's settled (used to decide whether delivery needs a payment ticket).
--
-- Re-runnable.
-- =============================================================================

-- 1. sale_lines: a line is either a product or a string job (exactly one).
alter table sale_lines alter column product_id drop not null;
alter table sale_lines add column if not exists string_job_id uuid references string_jobs (id);
alter table sale_lines drop constraint if exists sale_lines_one_ref;
alter table sale_lines
  add constraint sale_lines_one_ref
  check ((product_id is null) <> (string_job_id is null));
create index if not exists idx_sale_lines_string_job on sale_lines (string_job_id);

-- 2. string_jobs: the sale that paid for this job (null = unpaid).
alter table string_jobs add column if not exists paid_sale_id uuid references sales (id);

-- 3. record_sale: product lines decrement stock; string-job lines mark the job
--    paid. Each line carries exactly one of product_id / string_job_id.
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
  v_product   uuid;
  v_job       uuid;
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
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;
    if (v_product is not null) = (v_job is not null) then
      raise exception 'A sale line must reference exactly one of product or string job';
    end if;

    if v_product is not null then
      if not exists (select 1 from products where id = v_product) then
        raise exception 'Unknown product_id % in sale line', v_product;
      end if;
      insert into sale_lines (sale_id, product_id, qty, unit_price)
      values (v_sale_id, v_product, v_qty, v_price);
      insert into inventory_txns (txn_type, product_id, qty, sale_id)
      values ('sell', v_product, -v_qty, v_sale_id);
    else
      if not exists (select 1 from string_jobs where id = v_job) then
        raise exception 'Unknown string_job_id % in sale line', v_job;
      end if;
      insert into sale_lines (sale_id, string_job_id, qty, unit_price)
      values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
    end if;

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  update sales set subtotal = v_subtotal where id = v_sale_id;
  return v_sale_id;
end;
$$;
grant execute on function record_sale(jsonb, uuid, text) to authenticated;
