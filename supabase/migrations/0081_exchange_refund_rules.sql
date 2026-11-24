-- =============================================================================
-- 0081_exchange_refund_rules.sql — an exchange's credit is refunded the way
-- the original sale was paid (AceStock, Phase 3D review)
--
-- Before (0077):
--   • A later refund of an exchange's new sale counted the part paid by the
--     return's credit as no payment type at all, so any money back for it was
--     a payment-type change. With a reason it could then go out as cash even
--     when the original sale was paid by card.
--   • record_exchange passed its new lines to record_sale unchecked, so a
--     call through the API could load a gift card with the return's credit,
--     turning a card or cash purchase into gift card money without the reason
--     a refund onto a gift card needs.
--
-- Now:
--   1. sale_refundable_by_method (same as 0054 otherwise): for an exchange's
--      new sale, each money payment type can also give back up to the
--      exchange's credit, but no more than the original sale still has left
--      that way. More than that, or to another type, still needs a reason.
--      Gift cards keep their own per-card rule (refund_method_overages).
--   2. record_exchange (same as 0077 otherwise) refuses a gift card load among
--      the new items.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. sale_refundable_by_method — an exchange's credit counts as the original's
--    payment types
-- -----------------------------------------------------------------------------
create or replace function sale_refundable_by_method(p_sale_id uuid, p_refund_id uuid)
returns table (method text, refundable numeric)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with exchange_credit as (
    -- The exchange that paid for this sale with returned items, if any, and
    -- the sale those items came from.
    select e.credit, r.sale_id as original_sale_id
      from exchanges e join refunds r on r.id = e.refund_id
     where e.sale_id = p_sale_id
  )
  select m.method,
         greatest(
           coalesce((select sum(sp.amount) from sale_payments sp
                      where sp.sale_id = p_sale_id and sp.method = m.method), 0)
         + coalesce((select least(c.credit, greatest(
                        coalesce((select sum(sp.amount) from sale_payments sp
                                   where sp.sale_id = c.original_sale_id and sp.method = m.method), 0)
                      - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                                   where r.sale_id = c.original_sale_id and rp.method = m.method), 0),
                        0))
                       from exchange_credit c
                      where m.method <> 'gift_card'), 0)
         - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                      where r.sale_id = p_sale_id and r.id is distinct from p_refund_id and rp.method = m.method), 0),
           0)
    from (values ('cash'), ('credit'), ('gift_card'), ('store_credit'), ('check')) as m(method);
$$;

revoke all on function sale_refundable_by_method(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. record_exchange — no gift card loads among the new items
-- -----------------------------------------------------------------------------
create or replace function record_exchange(
  p_sale_id              uuid,
  p_return_lines         jsonb,
  p_new_lines            jsonb,
  p_customer_id          uuid,
  p_payments             jsonb,
  p_refund_payments      jsonb,
  p_reason               text,
  p_ticket               jsonb default null,
  p_approval_id          uuid default null,
  p_method_change_reason text default null,
  p_refund_approval_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_exchange_id uuid := gen_random_uuid();
  v_refund_id   uuid;
  v_sale_id     uuid;
  v_credit      numeric;
begin
  perform require_staff();

  -- The return's credit buys goods, not gift card value: a load would turn a
  -- card or cash purchase into gift card money without the reason a refund
  -- onto a gift card needs (0081).
  if jsonb_typeof(p_new_lines) = 'array' and exists (
       select 1 from jsonb_array_elements(p_new_lines) l where nullif(l->>'gift_card_id', '') is not null) then
    raise exception 'An exchange can''t load a gift card: refund the items onto the card instead';
  end if;

  -- record_refund and record_sale read these transaction-local settings.
  -- Only this function sets them: the API can't call set_config (pg_catalog
  -- isn't exposed), and nothing else sets acestock.exchange_*.
  perform set_config('acestock.exchange_id', v_exchange_id::text, true);
  v_refund_id := record_refund(p_sale_id, p_return_lines, coalesce(p_refund_payments, '[]'::jsonb),
                               coalesce(nullif(btrim(p_reason), ''), 'Exchange'), null,
                               p_method_change_reason, p_refund_approval_id);
  perform set_config('acestock.exchange_id', '', true);

  select coalesce(sum(amount), 0) into v_credit
    from refund_payments where refund_id = v_refund_id and method = 'exchange';

  perform set_config('acestock.exchange_credit', v_credit::text, true);
  v_sale_id := record_sale(p_new_lines, p_customer_id, coalesce(p_payments, '[]'::jsonb), 'Exchange',
                           p_ticket, p_approval_id);
  perform set_config('acestock.exchange_credit', '', true);

  insert into exchanges (id, refund_id, sale_id, credit) values (v_exchange_id, v_refund_id, v_sale_id, v_credit);

  return jsonb_build_object('exchange_id', v_exchange_id, 'refund_id', v_refund_id, 'sale_id', v_sale_id,
                            'credit', v_credit);
end;
$$;

revoke all on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) from public, anon;
grant execute on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) to authenticated;
