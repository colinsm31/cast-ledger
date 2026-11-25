-- =============================================================================
-- 0087_receipt_emails.sql — emailing a sale's receipt (AceStock, Phase 3E;
-- moved here from 2C)
--
-- Before:
--   • A receipt could only be printed (2C, /sales/:id/receipt).
--
-- Now:
--   queue_receipt_email puts a receipt email in the message log (0086) for the
--   send-notifications Edge Function to send. The web app draws the email from
--   the same receipt data as the printed letter layout; here the request is
--   checked:
--     • staff only (require_staff);
--     • a valid address, and a sale that exists;
--     • the subject is set here ("Your receipt from <shop> (<number>)"), not
--       taken from the request;
--     • the HTML is at most 200 KB with no script or javascript: link, and the
--       plain-text copy at most 20,000 characters;
--     • at most 5 receipt emails per sale per hour, counted with the sale row
--       locked, so a stuck button can't flood an inbox.
--   A receipt is sent because the customer asked at the counter, so it needs
--   no opt-in (0085 is for ready notices).
--
-- Re-runnable.
-- =============================================================================

create or replace function queue_receipt_email(
  p_sale_id uuid,
  p_to      text,
  p_html    text,
  p_text    text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_to       text := btrim(coalesce(p_to, ''));
  v_customer uuid;
  v_shop     text;
  v_recent   integer;
  v_id       uuid;
begin
  perform require_staff();
  if not is_valid_email(v_to) then
    raise exception 'Enter a valid email address for the receipt';
  end if;
  select customer_id into v_customer from sales where id = p_sale_id for update;
  if not found then
    raise exception 'Unknown sale %', p_sale_id;
  end if;
  if nullif(btrim(coalesce(p_text, '')), '') is null or char_length(p_text) > 20000 then
    raise exception 'The receipt''s text is missing or too long';
  end if;
  if nullif(btrim(coalesce(p_html, '')), '') is null or octet_length(p_html) > 200000 then
    raise exception 'The receipt''s page is missing or too large';
  end if;
  if p_html ~* '<\s*script|javascript\s*:' then
    raise exception 'The receipt''s page can''t contain scripts';
  end if;

  select count(*) into v_recent
    from notifications
   where sale_id = p_sale_id and kind = 'receipt' and created_at > now() - interval '1 hour';
  if v_recent >= 5 then
    raise exception 'This receipt was already emailed 5 times in the last hour; try again later';
  end if;

  select coalesce(nullif(btrim(shop_name), ''), 'us') into v_shop from settings where id;
  insert into notifications (kind, channel, customer_id, sale_id, to_address, subject, body, html)
  values ('receipt', 'email', v_customer, p_sale_id, v_to,
          format('Your receipt from %s (%s)', coalesce(v_shop, 'us'),
                 upper(left(replace(p_sale_id::text, '-', ''), 8))),
          p_text, p_html)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function queue_receipt_email(uuid, text, text, text) from public, anon;
grant execute on function queue_receipt_email(uuid, text, text, text) to authenticated;
