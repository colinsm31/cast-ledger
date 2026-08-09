-- =============================================================================
-- 0026_gift_card_adjust.sql — manual gift card balance adjustment (AceStock)
--
-- Correct a card's balance without a sale: a signed ledger entry with a reason
-- (e.g. mistaken load, goodwill, zero-out). Cannot push the balance negative;
-- if the adjustment empties the card, its owner is cleared (consistent with
-- redemption). Re-runnable.
-- =============================================================================

create or replace function adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security invoker
as $$
declare
  v_bal numeric;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'Adjustment amount must be non-zero';
  end if;
  if not exists (select 1 from gift_cards where id = p_gift_card_id) then
    raise exception 'Unknown gift card %', p_gift_card_id;
  end if;

  select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = p_gift_card_id;
  if v_bal + p_amount < 0 then
    raise exception 'Adjustment would make the balance negative (balance %, adjustment %)', v_bal, p_amount;
  end if;

  insert into gift_card_txns (gift_card_id, amount, reason)
  values (p_gift_card_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'adjust'));

  v_bal := v_bal + p_amount;
  if v_bal <= 0 then
    update gift_cards set customer_id = null where id = p_gift_card_id;
  end if;
  return v_bal;
end;
$$;
grant execute on function adjust_gift_card(uuid, numeric, text) to authenticated;
