-- =============================================================================
-- 0094_sale_line_costs.sql — each sale line keeps its cost (AceStock, Phase 4A)
--
-- Before: a sale recorded what the customer paid, but not what the item cost
-- the shop. The only cost was the product's current cost, which changes, so a
-- margin report would rewrite past months every time a cost was edited.
--
-- Now:
--   1. sale_lines.unit_cost — the product's cost when the line was sold. Set by
--      the database as the line is saved (trigger below), whatever the caller
--      sends, so record_sale and record_exchange don't change. Stringing
--      charges and gift card loads have no cost (null). A product with no cost
--      recorded gives null too: reports count it as "no cost", never as $0.
--   2. sale_lines.unit_cost_estimated — true for lines sold before this
--      migration, whose cost is filled in from the product's cost today
--      (fill_estimated_sale_line_costs, run once below). Reports mark margins
--      that use them as estimated.
--
-- Re-runnable.
-- =============================================================================

-- 1. Columns ------------------------------------------------------------------
alter table sale_lines add column if not exists unit_cost numeric(12, 2);
alter table sale_lines add column if not exists unit_cost_estimated boolean not null default false;
alter table sale_lines drop constraint if exists ck_sale_lines_unit_cost;
alter table sale_lines add constraint ck_sale_lines_unit_cost
  check (unit_cost >= 0 and unit_cost <> 'NaN');

comment on column sale_lines.unit_cost is
  'The product''s cost when the line was sold (null: not a product line, or no cost recorded). Set by trg_sale_lines_unit_cost (0094).';
comment on column sale_lines.unit_cost_estimated is
  'True when unit_cost was filled in later from the product''s cost at the time (lines sold before 0094).';

-- 2. Keep the cost as each line is saved -------------------------------------
create or replace function set_sale_line_unit_cost()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.unit_cost := case
    when new.product_id is null then null
    else (select p.cost from products p where p.id = new.product_id)
  end;
  new.unit_cost_estimated := false;
  return new;
end;
$$;

revoke all on function set_sale_line_unit_cost() from public, anon, authenticated;

drop trigger if exists trg_sale_lines_unit_cost on sale_lines;
create trigger trg_sale_lines_unit_cost
  before insert on sale_lines
  for each row execute function set_sale_line_unit_cost();

-- 3. Lines sold before now: today's cost, marked estimated -------------------
-- A function so the tests can run exactly what the migration runs. Internal:
-- nobody signed in can call it.
create or replace function fill_estimated_sale_line_costs()
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  update sale_lines sl
     set unit_cost = p.cost,
         unit_cost_estimated = true
    from products p
   where p.id = sl.product_id
     and sl.unit_cost is null
     and not sl.unit_cost_estimated
     and p.cost is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function fill_estimated_sale_line_costs() from public, anon, authenticated;

select fill_estimated_sale_line_costs();
