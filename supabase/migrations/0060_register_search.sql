-- =============================================================================
-- 0060_register_search.sql — finding items at the register without a barcode
-- (AceStock, Phase 2D)
--
-- Before:
--   • The register could only add a product by scanning its barcode, so an
--     item with no or a damaged label couldn't be rung up.
--
-- Now:
--   1. search_products(term, limit): active products where every word typed
--      appears in the brand, name, SKU, barcode or an attribute value
--      ("babolat 16 white" finds the white 16-gauge Babolat string). Like
--      search_customers (0037) it runs with the caller's rights, so only staff
--      see results, and the typed text is matched literally.
--   2. products.quick_pick: common items (an overgrip, a can of balls) the
--      register shows as one-tap buttons.
--
-- Re-runnable.
-- =============================================================================

alter table products add column if not exists quick_pick boolean not null default false;
comment on column products.quick_pick is 'Shown as a one-tap button at the register';
create index if not exists ix_products_quick_pick on products (lower(name)) where quick_pick and is_active;

create or replace function search_products(p_term text, p_limit integer default 10)
returns setof products
language sql
security invoker
stable
set search_path = public, pg_temp
as $$
  with words as (
    -- Each word, with LIKE wildcards escaped so it's matched literally.
    select '%' || replace(replace(replace(word, '\', '\\'), '%', '\%'), '_', '\_') || '%' as contains
    from regexp_split_to_table(btrim(coalesce(p_term, '')), '\s+') as word
    where word <> ''
  )
  select p.*
  from products p
  where p.is_active
    and exists (select 1 from words)
    and not exists (
      select 1 from words w
      where not (
           coalesce(p.brand, '') ilike w.contains
        or p.name ilike w.contains
        or coalesce(p.sku, '') ilike w.contains
        or coalesce(p.barcode, '') ilike w.contains
        or exists (select 1 from jsonb_each_text(p.attributes) a where a.value ilike w.contains)
      )
    )
  order by lower(coalesce(p.brand, '')), lower(p.name)
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

revoke all on function search_products(text, integer) from public, anon;
grant execute on function search_products(text, integer) to authenticated;
