-- =============================================================================
-- 0114_drawers_wait_for_time_zone.sql — setting up can't stop cash sales
-- (AceStock, 4B review 7)
--
-- "Cash needs an open drawer" is on by default (0109), but a drawer can't be
-- opened until an admin sets the shop's time zone. Released as it was, every
-- cash sale and cash refund would be refused until then. Now the check starts
-- once the time zone is set; until then cash goes through, in no drawer.
--
-- check_cash_drawer is as in 0113 apart from that. Re-runnable.
-- =============================================================================

create or replace function check_cash_drawer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_session uuid;
  v_action  text;
  v_drawer  drawers%rowtype;
begin
  -- Drawers start once the shop's time zone is set (a drawer can't be opened
  -- without it), so a new install or release never stops cash sales.
  if new.method <> 'cash'
     or not coalesce((select cash_needs_drawer and time_zone is not null from settings where id), false) then
    return new;
  end if;
  if tg_table_name = 'sale_payments' then
    select drawer_session_id into v_session from sales where id = new.sale_id;
    v_action := 'taking cash';
  else
    select drawer_session_id into v_session from refunds where id = new.refund_id;
    v_action := 'giving cash back';
  end if;
  if v_session is not null then
    return new;
  end if;

  -- The register's drawer: the one it names, else the only one in use (review 2).
  select * into v_drawer from drawers where id = requested_drawer_id();
  if not found and (select count(*) from drawers where is_active) = 1 then
    select * into v_drawer from drawers where is_active;
  end if;
  if v_drawer.id is not null then
    raise exception 'Open % on the Cash drawer screen before %', v_drawer.name, v_action using errcode = '22023';
  end if;
  if exists (select 1 from drawers where is_active) then
    raise exception 'Choose this register''s drawer on the Cash drawer screen before %', v_action using errcode = '22023';
  end if;
  raise exception 'Add a cash drawer in Settings before %', v_action using errcode = '22023';
end;
$$;
revoke all on function check_cash_drawer() from public, anon, authenticated;
