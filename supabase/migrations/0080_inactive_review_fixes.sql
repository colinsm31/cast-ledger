-- =============================================================================
-- 0080_inactive_review_fixes.sql — inactive customers can't be slipped past
-- (AceStock, Phase 3D review)
--
-- Before (0076):
--   • guard_active_customer read the customer without a lock. A demo or new
--     string job saved while set_customer_active was making the customer
--     inactive (it locks the customer, then checks for open jobs and demos)
--     could get through, leaving an inactive customer with a demo out.
--   • A racquet could be moved to another customer through the API while it
--     had an open job, so its old owner could be made inactive with that job
--     still open (set_customer_active looks for jobs through the racquet).
--   • search_customers listed inactive customers among active ones by name,
--     so the home search's Enter could open an inactive duplicate.
--
-- Now:
--   1. guard_active_customer takes a share lock on the customer: it waits for
--      a deactivation in progress and then sees it; a deactivation that comes
--      second waits for the new demo or job and then sees that.
--   2. guard_racket_owner: a racquet with a job open (entered or strung)
--      stays with its customer until the job is delivered or cancelled.
--   3. search_customers lists active customers first.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The customer guard waits for a deactivation in progress
-- -----------------------------------------------------------------------------
create or replace function guard_active_customer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_customer uuid;
  v_use      text;
  v_name     text;
  v_active   boolean;
begin
  case tg_table_name
    when 'sales' then
      v_customer := new.customer_id;
      v_use := 'be put on a sale';
    when 'demo_loans' then
      v_customer := new.customer_id;
      v_use := 'borrow a demo';
    when 'store_credit_txns' then
      v_customer := new.customer_id;
      v_use := 'use store credit';
    when 'string_jobs' then
      select customer_id into v_customer from customer_rackets where id = new.customer_racket_id;
      v_use := 'have a new string job';
  end case;
  -- A share lock waits for set_customer_active (which locks the customer for
  -- update) and then reads what it saved; it also makes a deactivation that
  -- starts now wait for this row, so its open-job and demo checks see it.
  select is_active, first_name || ' ' || last_name into v_active, v_name
    from customers where id = v_customer
    for share;
  if found and not v_active then
    raise exception '% is inactive, so they can''t %: make them active again first', v_name, v_use;
  end if;
  return new;
end;
$$;
revoke all on function guard_active_customer() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. A racquet with an open job stays with its customer
-- -----------------------------------------------------------------------------
create or replace function guard_racket_owner()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from string_jobs where customer_racket_id = old.id and status in ('entered', 'complete')) then
    raise exception 'This racquet has a string job open: deliver or cancel it before moving it to another customer';
  end if;
  return new;
end;
$$;
revoke all on function guard_racket_owner() from public, anon, authenticated;

drop trigger if exists trg_guard_racket_owner on customer_rackets;
create trigger trg_guard_racket_owner before update of customer_id on customer_rackets
  for each row when (new.customer_id is distinct from old.customer_id)
  execute function guard_racket_owner();

-- -----------------------------------------------------------------------------
-- 3. search_customers — same as 0076; active customers first
-- -----------------------------------------------------------------------------
create or replace function search_customers(p_term text, p_limit integer default 8, p_include_inactive boolean default false)
returns setof customers
language sql
security invoker
stable
set search_path = public, pg_temp
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
    and (c.is_active or coalesce(p_include_inactive, false))
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
  order by c.is_active desc, lower(c.last_name), lower(c.first_name)
  limit least(greatest(coalesce(p_limit, 8), 1), 50);
$$;
revoke all on function search_customers(text, integer, boolean) from public, anon;
grant execute on function search_customers(text, integer, boolean) to authenticated;
