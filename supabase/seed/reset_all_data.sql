-- =============================================================================
-- reset_all_data.sql — empty ALL data from AceStock (TEST DATABASES ONLY).
--
-- Truncates every table in the public schema EXCEPT:
--   * settings  — shop config (tax rate, stringing labor, etc.)
--   * profiles  — user accounts + admin/staff roles (so you stay logged in)
--
-- Keeps schema, views, functions, RLS policies, and grants intact. Idempotent.
--
-- DANGER: this deletes all products, units, stock, sales, refunds, gift cards,
-- store credit, customers, rackets, string jobs, categories, attributes, and
-- lookup lists. Do NOT run against production.
-- =============================================================================
do $$
declare
  t record;
begin
  for t in
    select tablename
    from pg_tables
    where schemaname = 'public'
      and tablename not in ('settings', 'profiles')
  loop
    execute format('truncate table public.%I restart identity cascade', t.tablename);
  end loop;
end $$;
