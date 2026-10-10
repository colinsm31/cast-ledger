-- =============================================================================
-- 0035_staff_attribution.sql — record who did it (AceStock, Phase 1A)
--
-- Every money and stock record now carries the signed-in staff member who
-- created it. Columns default to auth.uid(), so the existing server functions
-- (record_sale, record_refund, receive_stock, ...) fill them in without being
-- rewritten, and so does any future client insert.
--
--   sales.user_id, inventory_txns.user_id   existed but were never set → default
--   refunds / gift_card_txns / store_credit_txns.user_id                → new
--   product_units.created_by                (who received the unit)     → new
--   string_jobs.entered_by / completed_by / delivered_by / cancelled_by → new
--   string_jobs.cancelled_at                                            → new
--
-- All attribution columns reference profiles (one row per staff account) so
-- the API can embed the staff member's email, and fall back to null if a staff
-- account is ever deleted. advance_string_job and cancel_string_job are
-- redefined to stamp the status-change columns. Behavior is otherwise unchanged.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Attribution columns: add (where missing), default to the signed-in user,
--    and point at profiles.
-- ----------------------------------------------------------------------------
alter table sales             add column if not exists user_id uuid;
alter table inventory_txns    add column if not exists user_id uuid;
alter table refunds           add column if not exists user_id uuid;
alter table gift_card_txns    add column if not exists user_id uuid;
alter table store_credit_txns add column if not exists user_id uuid;
alter table product_units     add column if not exists created_by uuid;
alter table string_jobs
  add column if not exists entered_by   uuid,
  add column if not exists completed_by uuid,
  add column if not exists delivered_by uuid,
  add column if not exists cancelled_by uuid,
  add column if not exists cancelled_at timestamptz;

do $$
declare
  -- {table, column, stamped on insert?}
  attribution_columns text[][] := array[
    array['sales',             'user_id',      'yes'],
    array['inventory_txns',    'user_id',      'yes'],
    array['refunds',           'user_id',      'yes'],
    array['gift_card_txns',    'user_id',      'yes'],
    array['store_credit_txns', 'user_id',      'yes'],
    array['product_units',     'created_by',   'yes'],
    array['string_jobs',       'entered_by',   'yes'],
    array['string_jobs',       'completed_by', 'no'],
    array['string_jobs',       'delivered_by', 'no'],
    array['string_jobs',       'cancelled_by', 'no']
  ];
  entry text[];
  table_name text;
  column_name text;
  constraint_name text;
begin
  foreach entry slice 1 in array attribution_columns loop
    table_name := entry[1];
    column_name := entry[2];
    constraint_name := format('%s_%s_fkey', table_name, column_name);

    if entry[3] = 'yes' then
      execute format('alter table %I alter column %I set default auth.uid()', table_name, column_name);
    end if;

    -- Any stray value that isn't a staff profile can't satisfy the foreign key.
    -- (Before this migration these columns were never written, so this is a
    -- no-op on real data; it only guards hand-edited test databases.)
    execute format(
      'update %I set %I = null where %I is not null and not exists (select 1 from profiles p where p.id = %I.%I)',
      table_name, column_name, column_name, table_name, column_name);

    execute format('alter table %I drop constraint if exists %I', table_name, constraint_name);
    execute format(
      'alter table %I add constraint %I foreign key (%I) references profiles (id) on delete set null',
      table_name, constraint_name, column_name);
  end loop;
end $$;

create index if not exists idx_sales_user   on sales (user_id);
create index if not exists idx_refunds_user on refunds (user_id);

-- ----------------------------------------------------------------------------
-- 2. advance_string_job — same rules as 0019, now records who completed /
--    delivered the job.
-- ----------------------------------------------------------------------------
create or replace function advance_string_job(
  p_job_id        uuid,
  p_target_status text
)
returns text
language plpgsql
security invoker
as $$
declare
  v_current text;
  v_rank    integer;
  v_target  integer;
  v_main    uuid;
  v_cross   uuid;
begin
  select status, main_product_id, cross_product_id
    into v_current, v_main, v_cross
    from string_jobs where id = p_job_id;
  if v_current is null then
    raise exception 'Unknown string job %', p_job_id;
  end if;

  v_rank   := case v_current       when 'entered' then 0 when 'complete' then 1 when 'delivered' then 2 else -1 end;
  v_target := case p_target_status when 'entered' then 0 when 'complete' then 1 when 'delivered' then 2 else -1 end;

  if v_target < 0 then
    raise exception 'Invalid status "%"', p_target_status;
  end if;
  if v_target <> v_rank + 1 then
    raise exception 'Cannot move a string job from "%" to "%"', v_current, p_target_status;
  end if;

  update string_jobs
    set status       = p_target_status,
        completed_at = case when p_target_status = 'complete'  then now()      else completed_at end,
        completed_by = case when p_target_status = 'complete'  then auth.uid() else completed_by end,
        delivered_at = case when p_target_status = 'delivered' then now()      else delivered_at end,
        delivered_by = case when p_target_status = 'delivered' then auth.uid() else delivered_by end
  where id = p_job_id;

  -- Consume one unit of each distinct catalog string the job used.
  if p_target_status = 'complete' then
    insert into inventory_txns (txn_type, product_id, qty, note)
    select 'consume', pid, -1, 'String job completed'
    from (
      select distinct pid
      from (values (v_main), (v_cross)) as t(pid)
      where pid is not null
    ) d;
  end if;

  return p_target_status;
end;
$$;

grant execute on function advance_string_job(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. cancel_string_job — same rules as 0020, now records who cancelled and when.
-- ----------------------------------------------------------------------------
create or replace function cancel_string_job(p_job_id uuid)
returns text
language plpgsql
security invoker
as $$
declare
  v_current text;
begin
  select status into v_current from string_jobs where id = p_job_id;
  if v_current is null then
    raise exception 'Unknown string job %', p_job_id;
  end if;
  if v_current <> 'entered' then
    raise exception 'Only an entered job can be cancelled (this one is "%")', v_current;
  end if;

  update string_jobs
     set status       = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid()
   where id = p_job_id;
  return 'cancelled';
end;
$$;

grant execute on function cancel_string_job(uuid) to authenticated;
