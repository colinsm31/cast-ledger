-- =============================================================================
-- 0076_deactivate_customers_and_gift_cards.sql — inactive customers and gift
-- cards (AceStock, Phase 3D)
--
-- Before:
--   • customers.is_active (0012) and gift_cards.is_active (0024) existed but
--     nothing read them. A customer with history can't be deleted (0073), and
--     a lost gift card stayed usable by whoever found it.
--   • Staff could flip customers.is_active directly, with no reason kept.
--
-- Now:
--   1. set_customer_active / set_gift_card_active turn a record off with a
--      reason (who and when kept too) or back on. A customer with a string job
--      open or a demo out can't be turned off until it's settled. Any store
--      credit or card balance stays, for when the record is turned back on.
--   2. Those columns change only through those functions, and a new customer
--      starts active.
--   3. An inactive customer can't be put on a sale, a new string job or a
--      demo, or have store credit added or used. An inactive gift card can't
--      be loaded, spent, refunded to or adjusted; only an unused load can
--      still come back off it (0075). Their history is untouched.
--   4. search_customers leaves inactive customers out unless asked
--      (p_include_inactive), so the register doesn't offer them.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------
alter table customers  add column if not exists deactivated_at     timestamptz;
alter table customers  add column if not exists deactivated_by     uuid references profiles (id);
alter table customers  add column if not exists deactivated_reason text;
alter table gift_cards add column if not exists deactivated_at     timestamptz;
alter table gift_cards add column if not exists deactivated_by     uuid references profiles (id);
alter table gift_cards add column if not exists deactivated_reason text;

comment on column customers.deactivated_reason is 'Why the customer was made inactive; cleared when made active again';
comment on column gift_cards.deactivated_reason is 'Why the card was made inactive (e.g. lost); cleared when made active again';

-- The register looks cards up by code here, so it says whether one is active.
create or replace view gift_card_balance with (security_invoker = true) as
select gc.id as gift_card_id, gc.code, gc.customer_id,
       coalesce(sum(t.amount), 0)::numeric as balance,
       gc.is_active
from gift_cards gc
left join gift_card_txns t on t.gift_card_id = gc.id
group by gc.id, gc.code, gc.customer_id, gc.is_active;
revoke all on gift_card_balance from anon;
grant select on gift_card_balance to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Only the functions below change whether a record is active
-- -----------------------------------------------------------------------------
create or replace function guard_active_flag()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_setting('acestock.set_active', true) = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.is_active          := true;
    new.deactivated_at     := null;
    new.deactivated_by     := null;
    new.deactivated_reason := null;
  elsif new.is_active is distinct from old.is_active
     or new.deactivated_at is distinct from old.deactivated_at
     or new.deactivated_by is distinct from old.deactivated_by
     or new.deactivated_reason is distinct from old.deactivated_reason then
    raise exception 'Make a record inactive or active again from its page (it keeps the reason)';
  end if;
  return new;
end;
$$;
revoke all on function guard_active_flag() from public, anon, authenticated;

drop trigger if exists trg_guard_active_flag on customers;
create trigger trg_guard_active_flag before insert or update on customers
  for each row execute function guard_active_flag();
drop trigger if exists trg_guard_active_flag on gift_cards;
create trigger trg_guard_active_flag before insert or update on gift_cards
  for each row execute function guard_active_flag();

-- -----------------------------------------------------------------------------
-- 3. Turning a record off or back on
-- -----------------------------------------------------------------------------
create or replace function set_customer_active(p_customer_id uuid, p_active boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_open   text[];
begin
  perform require_staff();
  perform 1 from customers where id = p_customer_id for update;
  if not found then
    raise exception 'Unknown customer %', p_customer_id;
  end if;
  if p_active is null then
    raise exception 'Say whether the customer is active';
  end if;

  if not p_active then
    if v_reason is null then
      raise exception 'Say why the customer is inactive';
    end if;
    if char_length(v_reason) > 200 then
      raise exception 'Keep the reason to 200 characters';
    end if;
    select array_remove(array[
             case when exists (select 1 from string_jobs j join customer_rackets r on r.id = j.customer_racket_id
                                where r.customer_id = p_customer_id and j.status in ('entered', 'complete'))
                  then 'a string job open' end,
             case when exists (select 1 from demo_loans where customer_id = p_customer_id and back_at is null)
                  then 'a demo out' end
           ], null)
      into v_open;
    if cardinality(v_open) > 0 then
      raise exception 'This customer has %: settle it before making them inactive', array_to_string(v_open, ' and ');
    end if;
  end if;

  perform set_config('acestock.set_active', 'on', true);
  update customers
     set is_active          = p_active,
         deactivated_at     = case when p_active then null else now() end,
         deactivated_by     = case when p_active then null else auth.uid() end,
         deactivated_reason = case when p_active then null else v_reason end,
         updated_at         = now()
   where id = p_customer_id;
  perform set_config('acestock.set_active', '', true);
end;
$$;

create or replace function set_gift_card_active(p_gift_card_id uuid, p_active boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform require_staff();
  perform 1 from gift_cards where id = p_gift_card_id for update;
  if not found then
    raise exception 'Unknown gift card %', p_gift_card_id;
  end if;
  if p_active is null then
    raise exception 'Say whether the gift card is active';
  end if;
  if not p_active and v_reason is null then
    raise exception 'Say why the gift card is inactive';
  end if;
  if char_length(coalesce(v_reason, '')) > 200 then
    raise exception 'Keep the reason to 200 characters';
  end if;

  perform set_config('acestock.set_active', 'on', true);
  update gift_cards
     set is_active          = p_active,
         deactivated_at     = case when p_active then null else now() end,
         deactivated_by     = case when p_active then null else auth.uid() end,
         deactivated_reason = case when p_active then null else v_reason end
   where id = p_gift_card_id;
  perform set_config('acestock.set_active', '', true);
end;
$$;

revoke all on function set_customer_active(uuid, boolean, text) from public, anon;
revoke all on function set_gift_card_active(uuid, boolean, text) from public, anon;
grant execute on function set_customer_active(uuid, boolean, text) to authenticated;
grant execute on function set_gift_card_active(uuid, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Inactive records can't be used
-- -----------------------------------------------------------------------------
-- Refuse an inactive customer on a sale, demo, store credit or new string job.
create or replace function guard_active_customer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_customer uuid;
  v_use      text;
  v_name     text;
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
  select first_name || ' ' || last_name into v_name from customers where id = v_customer and not is_active;
  if found then
    raise exception '% is inactive, so they can''t %: make them active again first', v_name, v_use;
  end if;
  return new;
end;
$$;
revoke all on function guard_active_customer() from public, anon, authenticated;

drop trigger if exists trg_guard_active_customer on sales;
create trigger trg_guard_active_customer before insert on sales
  for each row when (new.customer_id is not null) execute function guard_active_customer();
drop trigger if exists trg_guard_active_customer on demo_loans;
create trigger trg_guard_active_customer before insert on demo_loans
  for each row execute function guard_active_customer();
drop trigger if exists trg_guard_active_customer on store_credit_txns;
create trigger trg_guard_active_customer before insert on store_credit_txns
  for each row execute function guard_active_customer();
drop trigger if exists trg_guard_active_customer on string_jobs;
create trigger trg_guard_active_customer before insert on string_jobs
  for each row execute function guard_active_customer();

create or replace function guard_active_gift_card()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  -- An unused load can still come back off an inactive card (0075).
  if new.reason = 'load refund' then
    return new;
  end if;
  select code into v_code from gift_cards where id = new.gift_card_id and not is_active;
  if found then
    raise exception 'Gift card % is inactive, so it can''t be used: make it active again first', v_code;
  end if;
  return new;
end;
$$;
revoke all on function guard_active_gift_card() from public, anon, authenticated;

drop trigger if exists trg_guard_active_gift_card on gift_card_txns;
create trigger trg_guard_active_gift_card before insert on gift_card_txns
  for each row execute function guard_active_gift_card();

-- -----------------------------------------------------------------------------
-- 5. search_customers — same as 0037; inactive customers only when asked
-- -----------------------------------------------------------------------------
drop function if exists search_customers(text, integer);
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
  order by lower(c.last_name), lower(c.first_name)
  limit least(greatest(coalesce(p_limit, 8), 1), 50);
$$;
revoke all on function search_customers(text, integer, boolean) from public, anon;
grant execute on function search_customers(text, integer, boolean) to authenticated;
