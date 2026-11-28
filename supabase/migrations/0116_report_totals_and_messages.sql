-- =============================================================================
-- 0116_report_totals_and_messages.sql — daily report totals on the server, and
-- plain messages (AceStock, 4B review 14, 18)
--
--   1. report_day adds each side's total and the net (items, tax, total),
--      rounded once here, so the screens add nothing up and the Z copy saved
--      at a close carries them. A day still to come is refused.
--   2. close_drawer refuses a note over 500 characters with a plain message
--      (it was a raw check error); record_drawer_movement refuses an amount
--      too large to store (it was "numeric field overflow").
--
-- report_day as in 0111, close_drawer as in 0109, record_drawer_movement as
-- in 0115, except where marked. Re-runnable.
-- =============================================================================

drop function if exists report_day(date);
create or replace function report_day(p_day date)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_zone   text;
  v_from   timestamptz;
  v_to     timestamptz;
  v_result jsonb;
begin
  perform require_staff();
  if p_day is null then
    raise exception 'Choose a day' using errcode = '22023';
  end if;
  select time_zone into v_zone from settings where id;
  if v_zone is null then
    raise exception 'An admin needs to set the shop''s time zone in Settings first' using errcode = '22023';
  end if;
  if p_day > shop_day(now()) then
    raise exception 'That day hasn''t happened yet' using errcode = '22023';
  end if;
  v_from := p_day::timestamp at time zone v_zone;
  v_to := (p_day + 1)::timestamp at time zone v_zone;

  with a as (
    select * from daily_money_amounts(v_from, v_to, v_zone)
  ),
  is_item as (
    select a.*, (a.what = 'stringing' or a.what like 'sales:%') as item from a
  ),
  methods(method, label, ord) as (
    values ('cash', 'Cash', 1), ('credit', 'Card', 2), ('check', 'Check', 3),
           ('gift_card', 'Gift card', 4), ('store_credit', 'Store credit', 5)
  ),
  payments as (
    select m.method, m.label, m.ord,
           coalesce(sum(a.amt) filter (where a.source = 'sale'), 0) as taken,
           coalesce(-sum(a.amt) filter (where a.source = 'refund'), 0) as given_back
      from methods m left join a on a.what = m.method
     group by m.method, m.label, m.ord
  ),
  categories as (
    select case when what = 'stringing' then 'Stringing' else substr(what, 7) end as name,
           -coalesce(sum(amt) filter (where source = 'sale'), 0) as sold,
           coalesce(sum(amt) filter (where source = 'refund'), 0) as returned
      from is_item where item
     group by 1
  ),
  sessions as (
    select dr.name as drawer_name, ds.opened_at, ds.closed_at, ds.counted_cash,
           -- An open drawer's expected cash is worked out now; a closed one's as saved.
           coalesce(ds.expected_cash, x.expected_cash) as expected,
           x.float_amount, x.cash_sales, x.cash_refunds, x.paid_in, x.paid_out
      from drawer_sessions ds
      join drawers dr on dr.id = ds.drawer_id
      cross join lateral drawer_cash_summary(ds.id) x
     where ds.business_day = p_day
  )
  select jsonb_build_object(
    'day', p_day,
    'time_zone', v_zone,
    'sales', jsonb_build_object(
      'count', (select count(*) from sales where sold_at >= v_from and sold_at < v_to),
      'items', coalesce((select -sum(amt) from is_item where source = 'sale' and item), 0),
      'gift_cards', coalesce((select -sum(amt) from a where source = 'sale' and what = 'gift_card_sold'), 0),
      'tax', coalesce((select -sum(amt) from a where source = 'sale' and what = 'tax'), 0)),
    'refunds', jsonb_build_object(
      'count', (select count(*) from refunds where refunded_at >= v_from and refunded_at < v_to),
      'items', coalesce((select sum(amt) from is_item where source = 'refund' and item), 0),
      'gift_cards', coalesce((select sum(amt) from a where source = 'refund' and what = 'gift_card_sold'), 0),
      'tax', coalesce((select sum(amt) from a where source = 'refund' and what = 'tax'), 0)),
    'exchanges', jsonb_build_object(
      'count', (select count(*) from exchanges where created_at >= v_from and created_at < v_to),
      'credit', coalesce((select sum(credit) from exchanges where created_at >= v_from and created_at < v_to), 0)),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'label', label, 'taken', taken,
                                          'given_back', given_back, 'net', taken - given_back) order by ord)
        from payments where taken <> 0 or given_back <> 0), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'sold', sold, 'returned', returned, 'net', sold - returned)
                       order by name)
        from categories), '[]'::jsonb),
    'drawers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'drawer', drawer_name, 'opened_at', opened_at, 'closed_at', closed_at,
               'float', float_amount, 'cash_sales', cash_sales, 'cash_refunds', cash_refunds,
               'paid_in', paid_in, 'paid_out', paid_out, 'expected', expected,
               'counted', counted_cash, 'over_short', counted_cash - expected)
             order by drawer_name, opened_at)
        from sessions), '[]'::jsonb)
  ) into v_result;

  -- Totals, rounded here so every screen and the saved Z copy agree (review 18).
  v_result := jsonb_set(v_result, '{sales,total}', to_jsonb(round(
    (v_result #>> '{sales,items}')::numeric + (v_result #>> '{sales,gift_cards}')::numeric
    + (v_result #>> '{sales,tax}')::numeric, 2)));
  v_result := jsonb_set(v_result, '{refunds,total}', to_jsonb(round(
    (v_result #>> '{refunds,items}')::numeric + (v_result #>> '{refunds,gift_cards}')::numeric
    + (v_result #>> '{refunds,tax}')::numeric, 2)));
  v_result := v_result || jsonb_build_object('net', jsonb_build_object(
    'items', (v_result #>> '{sales,items}')::numeric - (v_result #>> '{refunds,items}')::numeric,
    'tax', (v_result #>> '{sales,tax}')::numeric - (v_result #>> '{refunds,tax}')::numeric,
    'total', (v_result #>> '{sales,total}')::numeric - (v_result #>> '{refunds,total}')::numeric));
  return v_result;
end;
$$;
revoke all on function report_day(date) from public, anon;
grant execute on function report_day(date) to authenticated;

create or replace function close_drawer(p_session_id uuid, p_counts jsonb, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session drawer_sessions%rowtype;
begin
  perform require_staff();
  select * into v_session from drawer_sessions where id = p_session_id for update;
  if not found then
    raise exception 'Drawer session not found' using errcode = 'P0002';
  end if;
  if v_session.closed_at is not null then
    raise exception 'This drawer has already been closed' using errcode = '22023';
  end if;
  if char_length(btrim(p_note)) > 500 then
    raise exception 'Keep the note to 500 characters' using errcode = '22023';
  end if;

  update drawer_sessions
     set closed_at = now(),
         closed_by = auth.uid(),
         counted_counts = p_counts,
         counted_cash = drawer_count_total(p_counts),
         expected_cash = (select s.expected_cash from drawer_cash_summary(p_session_id) s),
         close_note = nullif(btrim(p_note), '')
   where id = p_session_id;
end;
$$;
revoke all on function close_drawer(uuid, jsonb, text) from public, anon;
grant execute on function close_drawer(uuid, jsonb, text) to authenticated;

create or replace function record_drawer_movement(
  p_session_id uuid,
  p_kind       text,
  p_amount     numeric,
  p_reason     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_closed_at timestamptz;
  v_expected  numeric;
  v_id        uuid;
begin
  perform require_staff();
  if p_kind is null or p_kind not in ('paid_in', 'paid_out') then
    raise exception 'Choose paid in or paid out' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter an amount over $0' using errcode = '22023';
  end if;
  if p_amount > 999999.99 then
    raise exception 'That amount is too large' using errcode = '22023';
  end if;
  if p_amount <> round(p_amount, 2) then
    raise exception 'Use at most 2 decimal places' using errcode = '22023';
  end if;
  if char_length(btrim(p_reason)) > 200 then
    raise exception 'Keep the reason to 200 characters' using errcode = '22023';
  end if;

  select closed_at into v_closed_at from drawer_sessions where id = p_session_id for no key update;
  if not found then
    raise exception 'Drawer session not found' using errcode = 'P0002';
  end if;
  if v_closed_at is not null then
    raise exception 'This drawer has been closed' using errcode = '22023';
  end if;
  perform refuse_stale_drawer((select drawer_id from drawer_sessions where id = p_session_id));
  if p_kind = 'paid_out' then
    select s.expected_cash into v_expected from drawer_cash_summary(p_session_id) s;
    if p_amount > v_expected then
      raise exception 'The drawer should only hold %', to_char(v_expected, 'FM$999,999,990.00')
        using errcode = '22023';
    end if;
  end if;

  insert into drawer_movements (drawer_session_id, kind, amount, reason)
  values (p_session_id, p_kind, p_amount, nullif(btrim(p_reason), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function record_drawer_movement(uuid, text, numeric, text) from public, anon;
grant execute on function record_drawer_movement(uuid, text, numeric, text) to authenticated;
