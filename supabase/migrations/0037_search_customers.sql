-- =============================================================================
-- 0037_search_customers.sql — server-side customer search (AceStock, Phase 1A)
--
-- The home screen and the register used to build a PostgREST `or=(...)` filter
-- by pasting the typed text into it, so a name containing a comma or a
-- parenthesis broke the query, and only first/last name were searched. This
-- function is the single definition of customer search:
--
--   • first name, last name, "first last", "last, first", or email — a
--     case-insensitive substring match, with % _ \ in the input treated as
--     literal characters
--   • phone number — when the input looks like a phone number (only digits,
--     spaces and ( ) - . +, with 3+ digits), matched against the phone's digits
--     only, so "225-555", "(225) 555" and "225555" all find (225)555-1234
--
-- Ordered last name, first name; at most p_limit rows (1–50, default 8).
-- Security invoker: reads customers under the caller's existing RLS.
--
-- Re-runnable.
-- =============================================================================

create or replace function search_customers(p_term text, p_limit integer default 8)
returns setof customers
language sql
security invoker
stable
as $$
  with input as (
    select
      btrim(coalesce(p_term, ''))                              as term,
      regexp_replace(coalesce(p_term, ''), '\D', '', 'g')      as digits
  ),
  pattern as (
    select
      term,
      digits,
      -- Escape LIKE wildcards so the typed text is matched literally.
      '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%' as contains
    from input
  )
  select c.*
  from customers c, pattern p
  where p.term <> ''
    and (
         c.first_name ilike p.contains
      or c.last_name  ilike p.contains
      or (c.first_name || ' '  || c.last_name)  ilike p.contains
      or (c.last_name  || ', ' || c.first_name) ilike p.contains
      or c.email ilike p.contains
      or (
           p.term ~ '^[0-9()+.\s-]+$'
           and length(p.digits) >= 3
           and regexp_replace(coalesce(c.phone_number, ''), '\D', '', 'g') like '%' || p.digits || '%'
         )
    )
  order by lower(c.last_name), lower(c.first_name)
  limit least(greatest(coalesce(p_limit, 8), 1), 50);
$$;

grant execute on function search_customers(text, integer) to authenticated;
