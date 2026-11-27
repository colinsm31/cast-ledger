-- =============================================================================
-- 0098_report_balances.sql — gift card and store credit liability (AceStock, Phase 4A)
--
-- Adds report_balances(as_of): what the shop owes on gift cards and store
-- credit at a moment — every card or customer with a balance then, summed from
-- its history before that moment (a balance is always the sum of its
-- history). One row each:
--   * kind: 'gift_card' or 'store_credit';
--   * code: the card's code (gift cards);
--   * customer: last name, first name, when there is one;
--   * balance, last_activity (the latest entry before the moment);
--   * is_active: an inactive card or customer still owes its balance, so it's
--     listed and marked.
-- Cards and customers at zero are left out.
--
-- Admins only; runs with the caller's rights. Re-runnable.
-- =============================================================================

drop function if exists report_balances(timestamptz);
create or replace function report_balances(p_as_of timestamptz)
returns table (
  kind          text,
  holder_id     uuid,
  code          text,
  customer      text,
  balance       numeric,
  last_activity timestamptz,
  is_active     boolean
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  if p_as_of is null then
    raise exception 'Choose the moment to report balances at'
      using errcode = '22023';
  end if;

  return query
  with cards as (
    select t.gift_card_id as id, sum(t.amount) as bal, max(t.created_at) as last_at
      from gift_card_txns t
     where t.created_at < p_as_of
     group by t.gift_card_id
    having sum(t.amount) <> 0
  ),
  credit as (
    select t.customer_id as id, sum(t.amount) as bal, max(t.created_at) as last_at
      from store_credit_txns t
     where t.created_at < p_as_of
     group by t.customer_id
    having sum(t.amount) <> 0
  )
  select 'gift_card'::text, gc.id, gc.code,
         case when cu.id is not null then cu.last_name || ', ' || cu.first_name end,
         c.bal, c.last_at, gc.is_active
    from cards c
    join gift_cards gc on gc.id = c.id
    left join customers cu on cu.id = gc.customer_id
  union all
  select 'store_credit'::text, cu.id, null::text,
         cu.last_name || ', ' || cu.first_name,
         c.bal, c.last_at, cu.is_active
    from credit c
    join customers cu on cu.id = c.id
  order by 1, 4 nulls last, 3;
end;
$$;

revoke all on function report_balances(timestamptz) from public, anon;
grant execute on function report_balances(timestamptz) to authenticated;
