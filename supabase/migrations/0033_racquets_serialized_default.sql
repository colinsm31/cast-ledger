-- =============================================================================
-- 0033_racquets_serialized_default.sql — rackets are always serialized (AceStock)
--
-- Serialization is a property of the category, not something to toggle per
-- product: every product under a "serialized" category (Racquets) is tracked as
-- individual units. This adds a categories.serialized_default flag, turns it on
-- for Racquets, backfills existing racket products, and enforces it on insert so
-- new rackets are serialized no matter how they're created.
--
-- Re-runnable.
-- =============================================================================

-- 1. Category-level flag: products in this category are serialized (unit-tracked).
alter table categories
  add column if not exists serialized_default boolean not null default false;

-- 2. Racquets is serialized. (Match common spellings to be safe.)
update categories set serialized_default = true
  where lower(name) in ('racquets', 'rackets');

-- 3. Backfill: existing products in a serialized category become serialized.
update products p
   set is_serialized = true
  from categories c
 where c.id = p.category_id
   and c.serialized_default
   and p.is_serialized = false;

-- 4. Enforce on insert (and on a category change): a product in a serialized
--    category is always serialized, regardless of what the client sent.
create or replace function apply_serialized_default()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1 from categories c
    where c.id = new.category_id and c.serialized_default
  ) then
    new.is_serialized := true;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_apply_serialized_default on products;
create trigger trg_apply_serialized_default
  before insert or update of category_id on products
  for each row execute function apply_serialized_default();
