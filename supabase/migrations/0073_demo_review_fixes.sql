-- =============================================================================
-- 0073_demo_review_fixes.sql — fixes from the Phase 3C review (AceStock)
--
-- Before:
--   • A demo was linked to a sale only if it went out in the 30 days before
--     the sale, so a long loan bought on its return was never linked.
--   • Buying two frames of a racquet demoed twice linked both demos to the
--     same sale.
--   • Deleting a customer with demo loans showed a raw foreign-key error.
--   • The staff-only write check of 0041 (trg_enforce_staff_writer) was only
--     put on the tables that existed then. demo_loans, discount_approvals,
--     held_tickets and unit_status_changes don't have it. Nothing is exposed
--     today (their server functions check for staff), but it's the backstop.
--
-- Now:
--   1. link_demo_sale (0072): a demo counts if it's still out or came back in
--      the 30 days before the sale, and one sale is linked to at most one
--      demo of each racquet.
--   2. guard_customer_delete (0046): demos are history too, named in the
--      message like sales and string jobs.
--   3. Every public table without trg_enforce_staff_writer gets it, as in
--      0041. Test 43 keeps it that way for tables added later.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- link_demo_sale — same as 0072, with the window from the demo's return and
-- one demo per racquet per sale
-- -----------------------------------------------------------------------------
create or replace function link_demo_sale()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status <> 'sold' or old.status = 'sold' or new.customer_id is null or new.sale_id is null then
    return new;
  end if;
  -- Another frame of this racquet on the same sale already credited a demo.
  if exists (select 1 from demo_loans l join product_units u on u.id = l.product_unit_id
              where l.sale_id = new.sale_id and u.product_id = new.product_id) then
    return new;
  end if;

  update demo_loans
     set sale_id = new.sale_id
   where id = (
     select l.id
       from demo_loans l
       join product_units u on u.id = l.product_unit_id
      where l.customer_id = new.customer_id
        and u.product_id = new.product_id
        and l.sale_id is null
        and coalesce(l.back_at, now()) >= now() - interval '30 days'
      order by l.out_at desc, l.loan_number desc
      limit 1
      for update of l
   );
  return new;
end;
$$;

revoke all on function link_demo_sale() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- guard_customer_delete — same as 0046, plus demos
-- -----------------------------------------------------------------------------
create or replace function guard_customer_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_history text[];
begin
  select array_remove(array[
           case when exists (select 1 from sales where customer_id = old.id) then 'sales' end,
           case when exists (select 1 from store_credit_txns where customer_id = old.id) then 'store credit' end,
           case when exists (select 1 from gift_cards where customer_id = old.id) then 'gift cards' end,
           case when exists (select 1 from product_units where customer_id = old.id) then 'racquet units' end,
           case when exists (select 1 from string_jobs j join customer_rackets r on r.id = j.customer_racket_id
                              where r.customer_id = old.id) then 'string jobs' end,
           case when exists (select 1 from demo_loans where customer_id = old.id) then 'demo' end
         ], null)
    into v_history;
  if cardinality(v_history) > 0 then
    raise exception '% % has % history, so they can''t be deleted',
      old.first_name, old.last_name, array_to_string(v_history, ', ');
  end if;
  return old;
end;
$$;

revoke all on function guard_customer_delete() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- The staff-only write check (0041) on every table that lacks it
-- -----------------------------------------------------------------------------
do $$
declare
  tbl text;
begin
  for tbl in
    select c.relname
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relkind = 'r'
       and not exists (select 1 from pg_trigger t
                        where t.tgrelid = c.oid and t.tgname = 'trg_enforce_staff_writer')
  loop
    execute format(
      'create trigger trg_enforce_staff_writer before insert or update or delete on %I '
      'for each statement execute function enforce_staff_writer()', tbl);
  end loop;
end $$;
