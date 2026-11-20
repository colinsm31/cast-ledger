-- =============================================================================
-- 0067_unit_status_changes.sql — retire a frame or move it to demo, with a
-- reason, and keep each frame's history (AceStock, Phase 3B)
--
-- Before:
--   • A frame (product_units row) only changed status when it was sold. A
--     damaged frame or one set aside as a demo couldn't be taken out of
--     stock, and nothing recorded why or by whom.
--
-- Now:
--   1. unit_status_changes: every status a frame has had — received, sold,
--      moved to demo, retired, back in stock — with the reason, the sale (for
--      a sale), who did it and when. Written by a trigger on product_units, so
--      sales and receipts are recorded too. Read-only for staff.
--   2. set_unit_status(unit, status, reason): staff move a frame between
--      in_stock, demo and retired, giving a reason (at most 200 characters).
--      'sold' is set by sales (and, later, returns); 'assigned' is left for the
--      demo program (3C). Owner rights, staff only, the frame locked.
--
-- Re-runnable.
-- =============================================================================

create table if not exists unit_status_changes (
  id              uuid primary key default gen_random_uuid(),
  product_unit_id uuid not null references product_units (id),
  from_status     text,           -- null when the frame was received
  to_status       text not null,
  reason          text,
  sale_id         uuid references sales (id),
  refund_id       uuid references refunds (id),
  changed_by      uuid references profiles (id),
  changed_at      timestamptz not null default now()
);
comment on table unit_status_changes is 'Each status a frame has had, with why and who';
create index if not exists ix_unit_status_changes_unit on unit_status_changes (product_unit_id, changed_at);

alter table unit_status_changes enable row level security;
drop policy if exists unit_status_changes_staff_select on unit_status_changes;
create policy unit_status_changes_staff_select on unit_status_changes
  for select to authenticated using (is_staff());
revoke all on unit_status_changes from anon;
revoke insert, update, delete, truncate on unit_status_changes from authenticated;
grant select on unit_status_changes to authenticated;

-- -----------------------------------------------------------------------------
-- log_unit_status — record each status a frame takes
-- -----------------------------------------------------------------------------
-- The reason and refund come from settings set by the function making the
-- change (acestock.unit_status_reason, acestock.unit_refund_id) for this
-- transaction only.
create or replace function log_unit_status()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;
  insert into unit_status_changes (product_unit_id, from_status, to_status, reason, sale_id, refund_id, changed_by)
  values (
    new.id,
    case when tg_op = 'UPDATE' then old.status end,
    new.status,
    nullif(current_setting('acestock.unit_status_reason', true), ''),
    case when new.status = 'sold' then new.sale_id end,
    nullif(current_setting('acestock.unit_refund_id', true), '')::uuid,
    auth.uid()
  );
  return new;
end;
$$;

revoke all on function log_unit_status() from public, anon, authenticated;

drop trigger if exists trg_log_unit_status on product_units;
create trigger trg_log_unit_status
  after insert or update of status on product_units
  for each row execute function log_unit_status();

-- Frames already in the shop start their history as they are now.
insert into unit_status_changes (product_unit_id, from_status, to_status, reason, sale_id, changed_at)
select u.id, null, u.status, 'Status when history began', u.sale_id, u.created_at
  from product_units u
 where not exists (select 1 from unit_status_changes c where c.product_unit_id = u.id);

-- -----------------------------------------------------------------------------
-- set_unit_status — staff move a frame in or out of stock, with a reason
-- -----------------------------------------------------------------------------
create or replace function set_unit_status(
  p_unit_id uuid,
  p_status  text,
  p_reason  text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform require_staff();

  if p_status is null or p_status not in ('in_stock', 'demo', 'retired') then
    raise exception 'A frame can be put in stock, in the demo fleet or retired here (not "%")', p_status;
  end if;
  if v_reason is null then
    raise exception 'Give a reason';
  end if;
  if char_length(v_reason) > 200 then
    raise exception 'Keep the reason to 200 characters';
  end if;

  select status into v_current from product_units where id = p_unit_id for update;
  if not found then
    raise exception 'Unknown unit %', p_unit_id;
  end if;
  if v_current = p_status then
    raise exception 'This frame is already %', replace(p_status, '_', ' ');
  end if;
  if v_current not in ('in_stock', 'demo', 'retired') then
    raise exception 'This frame is %, so it can''t be moved here', v_current;
  end if;

  perform set_config('acestock.unit_status_reason', v_reason, true);
  update product_units set status = p_status, updated_at = now() where id = p_unit_id;
  perform set_config('acestock.unit_status_reason', '', true);
  return p_status;
end;
$$;

revoke all on function set_unit_status(uuid, text, text) from public, anon;
grant execute on function set_unit_status(uuid, text, text) to authenticated;
