-- =============================================================================
-- 0065_customer_supplied_string.sql — the customer brings their own string
-- (AceStock, Phase 3A)
--
-- Before:
--   • Both the mains and the crosses had to be catalog strings, so a job where
--     the customer brought a set of string couldn't be entered at all.
--
-- Now:
--   1. string_jobs.main_customer_supplied / cross_customer_supplied: that side
--      uses the customer's own string. It has no catalog product, so no stock
--      is set aside or used up for it and it adds nothing to the price; its
--      brand and name are typed in (the name is required, each at most 80
--      characters). A hybrid can mix the customer's mains with the shop's
--      crosses, or the other way round.
--   2. guard_string_job_strings: as 0043 for a shop string; a customer side
--      needs a name and no product. Whose string a side uses is fixed once
--      the job is paid (the price was set by it) or strung.
--   3. guard_strung_job_strings: as 0042, also covering the two new columns.
--   4. The trigger functions added in 0063 and 0064 can't be called by
--      anyone, like the other trigger functions (0040).
--
-- The strings' price (string_job_strings_price) already skips a side with no
-- product, so a customer side is labor only. Re-runnable.
-- =============================================================================

alter table string_jobs add column if not exists main_customer_supplied boolean not null default false;
alter table string_jobs add column if not exists cross_customer_supplied boolean not null default false;
comment on column string_jobs.main_customer_supplied is 'The mains are the customer''s own string (no catalog product)';
comment on column string_jobs.cross_customer_supplied is 'The crosses are the customer''s own string (no catalog product)';

grant update (main_customer_supplied, cross_customer_supplied) on string_jobs to authenticated;

-- -----------------------------------------------------------------------------
-- guard_strung_job_strings — same as 0042, plus whose string each side is
-- -----------------------------------------------------------------------------
create or replace function guard_strung_job_strings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.status <> 'entered'
     and (new.main_product_id, new.main_brand, new.main_string, new.main_specs, new.main_tension,
          new.cross_product_id, new.cross_brand, new.cross_string, new.cross_specs, new.cross_tension,
          new.main_customer_supplied, new.cross_customer_supplied)
         is distinct from
         (old.main_product_id, old.main_brand, old.main_string, old.main_specs, old.main_tension,
          old.cross_product_id, old.cross_brand, old.cross_string, old.cross_specs, old.cross_tension,
          old.main_customer_supplied, old.cross_customer_supplied) then
    raise exception 'The strings on a % string job can''t be changed', old.status;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_strung_job_strings on string_jobs;
create trigger trg_guard_strung_job_strings
  before update of main_product_id, main_brand, main_string, main_specs, main_tension,
                   cross_product_id, cross_brand, cross_string, cross_specs, cross_tension,
                   main_customer_supplied, cross_customer_supplied
  on string_jobs
  for each row execute function guard_strung_job_strings();

-- -----------------------------------------------------------------------------
-- customer_string_side — one customer-supplied side: its tidied brand and name
-- -----------------------------------------------------------------------------
create or replace function customer_string_side(
  p_product_id uuid,
  p_brand      text,
  p_name       text,
  p_side       text
)
returns table (brand text, name text)
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_brand text := nullif(trim(p_brand), '');
  v_name  text := nullif(trim(p_name), '');
begin
  if p_product_id is not null then
    raise exception 'The % are the customer''s own string, so they can''t be a catalog string too', p_side;
  end if;
  if v_name is null then
    raise exception 'Enter the customer''s % string', p_side;
  end if;
  if char_length(v_name) > 80 or char_length(coalesce(v_brand, '')) > 80 then
    raise exception 'The customer''s % string: use at most 80 characters for the brand and the name', p_side;
  end if;
  return query select v_brand, v_name;
end;
$$;

-- The string guard runs with the caller's rights, so staff can call this; it
-- only checks and tidies the text it's given.
revoke all on function customer_string_side(uuid, text, text, text) from public, anon;
grant execute on function customer_string_side(uuid, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- guard_string_job_strings — same as 0043, plus customer-supplied sides
-- -----------------------------------------------------------------------------
create or replace function guard_string_job_strings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_main          record;
  v_cross         record;
  v_main_shop     boolean := not new.main_customer_supplied;
  v_cross_shop    boolean := not new.cross_customer_supplied;
  v_check_main    boolean;
  v_check_cross   boolean;
  v_strings_moved boolean;
  v_new_price     numeric;
  v_old_price     numeric;
begin
  -- Only entered jobs, and only writes by a signed-in user. A strung job's
  -- strings are refused by trg_guard_strung_job_strings.
  if auth.uid() is null or new.status <> 'entered' then
    return new;
  end if;

  -- A paid job's price was set by whose string it uses.
  if tg_op = 'UPDATE' and old.paid_sale_id is not null
     and (new.main_customer_supplied, new.cross_customer_supplied)
         is distinct from (old.main_customer_supplied, old.cross_customer_supplied) then
    raise exception 'This job is paid, so whose string it uses can''t change';
  end if;

  if (v_main_shop and new.main_product_id is null) or (v_cross_shop and new.cross_product_id is null) then
    raise exception 'Choose the mains and crosses strings from the catalog';
  end if;
  if new.main_tension is null or new.cross_tension is null then
    raise exception 'Enter the mains and crosses tension';
  end if;

  -- Availability is checked for shop strings the job doesn't already hold.
  v_check_main := v_main_shop
    and (tg_op = 'INSERT'
         or (new.main_product_id is distinct from old.main_product_id
             and new.main_product_id is distinct from old.cross_product_id));
  v_check_cross := v_cross_shop
    and new.cross_product_id is distinct from new.main_product_id
    and (tg_op = 'INSERT'
         or (new.cross_product_id is distinct from old.main_product_id
             and new.cross_product_id is distinct from old.cross_product_id));

  -- Each shop string's check locks it; take them in id order so two registers
  -- choosing the same pair of strings can't deadlock.
  if v_main_shop and v_cross_shop and new.cross_product_id < new.main_product_id then
    select * into v_cross from string_job_side(new.cross_product_id, new.id, v_check_cross, 'crosses');
    select * into v_main  from string_job_side(new.main_product_id,  new.id, v_check_main,  'mains');
  else
    if v_main_shop then
      select * into v_main from string_job_side(new.main_product_id, new.id, v_check_main, 'mains');
    else
      select s.brand, s.name, '{}'::jsonb as specs into v_main
        from customer_string_side(new.main_product_id, new.main_brand, new.main_string, 'mains') s;
    end if;
    if v_cross_shop then
      select * into v_cross from string_job_side(new.cross_product_id, new.id, v_check_cross, 'crosses');
    else
      select s.brand, s.name, '{}'::jsonb as specs into v_cross
        from customer_string_side(new.cross_product_id, new.cross_brand, new.cross_string, 'crosses') s;
    end if;
  end if;

  new.main_brand   := v_main.brand;
  new.main_string  := v_main.name;
  new.main_specs   := v_main.specs;
  new.cross_brand  := v_cross.brand;
  new.cross_string := v_cross.name;
  new.cross_specs  := v_cross.specs;

  -- Record the strings' catalog price when they're chosen (not on a
  -- tension-only edit, so later catalog price changes don't count). A
  -- customer's string has no product, so it adds nothing.
  v_strings_moved := tg_op = 'INSERT'
    or (new.main_product_id, new.cross_product_id) is distinct from (old.main_product_id, old.cross_product_id);
  if v_strings_moved then
    v_new_price := string_job_strings_price(new.main_product_id, new.cross_product_id);
    if tg_op = 'UPDATE' and old.paid_sale_id is not null
       and coalesce(current_setting('acestock.string_change_job', true), '') <> old.id::text then
      v_old_price := coalesce(old.strings_price, string_job_strings_price(old.main_product_id, old.cross_product_id));
      if v_new_price <> v_old_price then
        raise exception 'This job was paid for strings costing $%; the new strings cost $%. Use String change to settle the difference',
          to_char(v_old_price, 'FM999999990.00'), to_char(v_new_price, 'FM999999990.00');
      end if;
    end if;
    new.strings_price := v_new_price;
  end if;
  return new;
end;
$$;

revoke all on function guard_string_job_strings() from public, anon, authenticated;

drop trigger if exists trg_guard_string_job_strings on string_jobs;
create trigger trg_guard_string_job_strings
  before insert or update of main_product_id, main_brand, main_string, main_specs, main_tension,
                             cross_product_id, cross_brand, cross_string, cross_specs, cross_tension,
                             main_customer_supplied, cross_customer_supplied
  on string_jobs
  for each row execute function guard_string_job_strings();

-- -----------------------------------------------------------------------------
-- 0063 and 0064's trigger functions, closed like the others
-- -----------------------------------------------------------------------------
revoke all on function guard_string_job_promise() from public, anon, authenticated;
revoke all on function guard_string_job_assignment() from public, anon, authenticated;
