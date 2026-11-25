-- =============================================================================
-- 0092_exchange_split_payment_type.sql — an exchange whose credit came from
-- more than one payment type is a split sale (AceStock, Phase 3E review #17)
--
-- Before (0082): record_exchange replaced the new sale's one 'exchange'
-- payment with one per payment type the credit came from (cash, card, ...),
-- but left the sale's payment type as record_sale had set it for one
-- payment: 'exchange'. A sale with two payments read as paid one way.
--
-- Now: record_exchange (otherwise the same as 0082) works the payment type out
-- again after that split, as record_sale does: one payment, its type; more
-- than one, 'split'. Sales already saved that way are corrected.
--
-- Re-runnable.
-- =============================================================================

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

  -- The credit arrives as one 'exchange' payment (record_sale); it's
  -- replaced by the refund's split, so each part keeps the payment type it
  -- came from (0082).
  delete from sale_payments where sale_id = v_sale_id and method = 'exchange';
  insert into sale_payments (sale_id, method, amount, source_method, source_gift_card_id)
  select v_sale_id, 'exchange', rp.amount, rp.source_method, rp.source_gift_card_id
    from refund_payments rp
   where rp.refund_id = v_refund_id and rp.method = 'exchange';

  -- With the credit split by where it came from, the payment type is worked
  -- out again as record_sale does: one payment, its type; more, 'split' (0092).
  update sales
     set payment_method = (select case count(*) when 0 then null
                                                 when 1 then min(method)
                                                 else 'split' end
                             from sale_payments where sale_id = v_sale_id)
   where id = v_sale_id;

  insert into exchanges (id, refund_id, sale_id, credit) values (v_exchange_id, v_refund_id, v_sale_id, v_credit);

  return jsonb_build_object('exchange_id', v_exchange_id, 'refund_id', v_refund_id, 'sale_id', v_sale_id,
                            'credit', v_credit);
end;
$$;

revoke all on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) from public, anon;
grant execute on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) to authenticated;

-- Exchanges already saved with more than one payment.
update sales s
   set payment_method = 'split'
 where s.payment_method = 'exchange'
   and (select count(*) from sale_payments sp where sp.sale_id = s.id) > 1;
