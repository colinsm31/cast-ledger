-- =============================================================================
-- 0061_held_tickets.sql — held tickets in the database (AceStock, Phase 2D, #28)
--
-- Before:
--   • A ticket left open was kept only in that browser, one per staff member,
--     so it couldn't be picked up at another register.
--
-- Now:
--   1. held_tickets: named tickets put on hold, any number at once, visible
--      to all staff from any register. The ticket itself (its lines,
--      discounts and the string job it settles) is kept as the register's
--      JSON; the customer is kept as a reference so recalling it reads them
--      fresh.
--   2. A held ticket expires after settings.held_ticket_hours (default 72).
--      An expired ticket can't be recalled or updated, the register doesn't
--      list it, and it's deleted the next time a ticket is held (staff can
--      still read it until then, so the delete can reach it).
--   3. hold_ticket(name, customer, ticket, id): holds a ticket, or updates one
--      held earlier; recall_held_ticket(id): takes it off hold and returns it.
--      Recalling deletes it in the same statement, so two registers can't both
--      recall one ticket. Both run with the caller's rights.
--
-- Prices are refreshed by the register when it recalls a ticket. Re-runnable.
-- =============================================================================

alter table settings add column if not exists held_ticket_hours integer not null default 72;
alter table settings drop constraint if exists ck_settings_held_ticket_hours;
alter table settings add constraint ck_settings_held_ticket_hours check (held_ticket_hours between 1 and 720);
comment on column settings.held_ticket_hours is 'How long a held ticket is kept before it expires';

create table if not exists held_tickets (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  customer_id uuid references customers (id) on delete set null,
  ticket      jsonb not null,
  held_by     uuid not null default auth.uid() references profiles (id),
  held_at     timestamptz not null default now(),
  expires_at  timestamptz not null,
  constraint ck_held_tickets_name check (name = trim(name) and char_length(name) between 1 and 60),
  constraint ck_held_tickets_ticket check (
    jsonb_typeof(ticket) = 'object'
    and jsonb_typeof(ticket->'lines') = 'array'
    and jsonb_array_length(ticket->'lines') between 1 and 200
    and octet_length(ticket::text) <= 200000)
);
comment on table held_tickets is 'Register tickets put on hold, visible from any register until they expire';
create index if not exists ix_held_tickets_expires_at on held_tickets (expires_at);

alter table held_tickets enable row level security;
drop policy if exists held_tickets_staff_select on held_tickets;
drop policy if exists held_tickets_staff_insert on held_tickets;
drop policy if exists held_tickets_staff_update on held_tickets;
drop policy if exists held_tickets_staff_delete on held_tickets;
create policy held_tickets_staff_select on held_tickets
  for select to authenticated using (is_staff());
create policy held_tickets_staff_insert on held_tickets
  for insert to authenticated with check (is_staff() and held_by = auth.uid());
create policy held_tickets_staff_update on held_tickets
  for update to authenticated using (is_staff()) with check (is_staff());
create policy held_tickets_staff_delete on held_tickets
  for delete to authenticated using (is_staff());
revoke all on held_tickets from anon, authenticated;
grant select, insert, update, delete on held_tickets to authenticated;

-- -----------------------------------------------------------------------------
-- hold_ticket — put a ticket on hold, or update one held earlier
-- -----------------------------------------------------------------------------
create or replace function hold_ticket(
  p_name        text,
  p_customer_id uuid,
  p_ticket      jsonb,
  p_id          uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_hours   integer;
  v_id      uuid;
  v_expires timestamptz;
begin
  perform require_staff();
  if nullif(trim(p_name), '') is null then
    raise exception 'Give the held ticket a name';
  end if;
  if char_length(trim(p_name)) > 60 then
    raise exception 'A held ticket''s name can be at most 60 characters';
  end if;
  if jsonb_typeof(p_ticket->'lines') is distinct from 'array' or jsonb_array_length(p_ticket->'lines') = 0 then
    raise exception 'There''s nothing on the ticket to hold';
  end if;

  delete from held_tickets where expires_at <= now();
  select held_ticket_hours into v_hours from settings where id = true;
  v_expires := now() + make_interval(hours => coalesce(v_hours, 72));

  if p_id is not null then
    update held_tickets
       set name = trim(p_name), customer_id = p_customer_id, ticket = p_ticket, held_at = now(), expires_at = v_expires
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'That held ticket was recalled at another register or has expired';
    end if;
    return v_id;
  end if;

  insert into held_tickets (name, customer_id, ticket, expires_at)
  values (trim(p_name), p_customer_id, p_ticket, v_expires)
  returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- recall_held_ticket — take a ticket off hold and return it
-- -----------------------------------------------------------------------------
-- Returns { name, customer_id, ticket, held_by, held_at }.
create or replace function recall_held_ticket(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_held held_tickets;
begin
  perform require_staff();
  delete from held_tickets where id = p_id and expires_at > now() returning * into v_held;
  if v_held.id is null then
    raise exception 'That held ticket was recalled at another register or has expired';
  end if;
  return jsonb_build_object(
    'name', v_held.name, 'customer_id', v_held.customer_id, 'ticket', v_held.ticket,
    'held_by', v_held.held_by, 'held_at', v_held.held_at);
end;
$$;

revoke all on function hold_ticket(text, uuid, jsonb, uuid) from public, anon;
revoke all on function recall_held_ticket(uuid) from public, anon;
grant execute on function hold_ticket(text, uuid, jsonb, uuid) to authenticated;
grant execute on function recall_held_ticket(uuid) to authenticated;
