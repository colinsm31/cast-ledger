-- =============================================================================
-- 0090_server_built_receipt_email.sql — the receipt email is built here, from
-- the sale (AceStock, Phase 3E review #2)
--
-- Before (0087):
--   queue_receipt_email took the email's HTML and text from the browser and
--   only refused <script> and javascript: links. Links, forms and images got
--   through, so a stolen staff login could send any email to anyone from the
--   shop's address; the limit was 5 per sale per hour, so working through
--   many sales got around it.
--
-- Now:
--   1. receipt_email_content(sale, time zone) builds the email from the saved
--      sale and the shop's receipt settings, in the printed letter receipt's
--      layout (web ReceiptView / lib/receipt.ts): shop name and address;
--      receipt number, time, who served, customer; each line with its
--      discount note; savings, subtotal, tax, total, payments, refunds since;
--      gift card balances; return policy and footer. Every value is escaped.
--      A plain-text copy goes with it.
--   2. queue_receipt_email(sale, address, time zone) takes only those: the
--      browser can no longer supply any of the email's content. The time zone
--      only sets how the sale's time is written (an unknown one is UTC).
--   3. Besides 5 per sale per hour, at most 30 receipt emails an hour for the
--      whole shop, counted with the settings row locked.
--
--   Keep this in step with the printed receipt: a change to its layout is
--   made in both (receipt_email_content and web lib/receipt.ts).
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Small helpers (internal: no signed-in user calls them)
-- -----------------------------------------------------------------------------
create or replace function html_escape(p_text text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select replace(replace(replace(replace(replace(coalesce(p_text, ''),
           '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;
revoke all on function html_escape(text) from public, anon, authenticated;

-- "$12.50" (amounts are rounded to the cent, as the web's toCents does).
create or replace function receipt_dollars(p_amount numeric)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when round(coalesce(p_amount, 0), 2) < 0 then '-' else '' end
         || '$' || to_char(abs(round(coalesce(p_amount, 0), 2)), 'FM999999999990.00')
$$;
revoke all on function receipt_dollars(numeric) from public, anon, authenticated;

-- A discount as entered (above 1 = dollars, else a fraction): "$3.00 off each",
-- "12.5% off" (web describeDiscount).
create or replace function receipt_discount_words(p_discount numeric, p_scope text default 'each')
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when p_discount > 1 then receipt_dollars(p_discount) || ' off ' || p_scope
              else trim(trailing '.' from trim(trailing '0' from to_char(round(p_discount * 100, 2), 'FM999990.00')))
                   || '% off' end
$$;
revoke all on function receipt_discount_words(numeric, text) from public, anon, authenticated;

-- A gift card code with all but its last 4 characters hidden.
create or replace function mask_gift_card_code(p_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when char_length(p_code) > 4 then '••••' else '' end || right(p_code, 4)
$$;
revoke all on function mask_gift_card_code(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1. The email, built from the sale
-- -----------------------------------------------------------------------------
create or replace function receipt_email_content(p_sale_id uuid, p_time_zone text default 'UTC')
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_sale        sales%rowtype;
  v_settings    settings%rowtype;
  v_zone        text := 'UTC';
  v_number      text := upper(left(replace(p_sale_id::text, '-', ''), 8));
  v_customer    text;
  v_served_by   text;
  v_address     text[];
  v_head        text[];
  v_line        record;
  v_label       text;
  v_note        text;
  v_parts       text[];
  v_line_html   text := '';
  v_line_text   text[] := '{}';
  v_saved       numeric := 0;
  v_ticket_note text;
  v_totals      text[][] := '{}';  -- {label, value, strong}
  v_payment     record;
  v_refunded    numeric;
  v_cards       text[][] := '{}';  -- {label, balance}
  v_totals_html text := '';
  v_cards_html  text := '';
  v_text        text[] := '{}';
  v_html        text;
  i             integer;
begin
  select * into v_sale from sales where id = p_sale_id;
  if not found then
    raise exception 'Unknown sale %', p_sale_id;
  end if;
  select * into v_settings from settings where id;
  if exists (select 1 from pg_timezone_names where name = p_time_zone) then
    v_zone := p_time_zone;
  end if;

  select nullif(btrim(c.first_name || ' ' || coalesce(c.last_name, '')), '') into v_customer
    from customers c where c.id = v_sale.customer_id;
  select nullif(split_part(btrim(p.email), '@', 1), '') into v_served_by
    from profiles p where p.id = v_sale.user_id;
  select coalesce(array_agg(btrim(l) order by n), '{}') into v_address
    from unnest(string_to_array(coalesce(v_settings.shop_address, ''), E'\n')) with ordinality as a(l, n)
   where btrim(l) <> '';
  v_head := array['Receipt ' || v_number,
                  to_char(v_sale.sold_at at time zone v_zone, 'Mon FMDD, YYYY, FMHH12:MI AM')]
            || case when v_served_by is not null then array['Served by ' || v_served_by] else '{}'::text[] end
            || case when v_customer is not null then array['Customer: ' || v_customer] else '{}'::text[] end;

  -- Lines, in the order they were rung up.
  for v_line in
    select sl.*, gc.code as card_code, p.brand, p.name as product_name, p.attributes
      from sale_lines sl
      left join gift_cards gc on gc.id = sl.gift_card_id
      left join products p on p.id = sl.product_id
     where sl.sale_id = p_sale_id
     order by sl.created_at, sl.ctid
  loop
    v_label := case
      when v_line.card_code is not null then 'Gift card ' || mask_gift_card_code(v_line.card_code)
      when v_line.product_name is not null then
        array_to_string(array_remove(array[nullif(v_line.brand, ''), v_line.product_name]
          || coalesce((select array_agg(value) from jsonb_each_text(coalesce(v_line.attributes, '{}'::jsonb))
                        where value is not null and value <> ''), '{}'), null), ' ')
      when v_line.kind = 'string_change' then 'String change'
      else 'Stringing' end;

    v_note := null;
    if v_line.price_before_discount is not null
       and round(v_line.price_before_discount, 2) <> round(v_line.unit_price, 2) then
      v_parts := '{}';
      if coalesce(v_line.line_discount, 0) <> 0 then
        v_parts := v_parts || array_to_string(array_remove(array[receipt_discount_words(v_line.line_discount),
                                                                  nullif(v_line.discount_reason, '')], null), ' · ');
      end if;
      if round(coalesce(v_line.ticket_discount_each, 0), 2) > 0 then
        v_parts := v_parts || 'ticket discount'::text;
      end if;
      v_note := receipt_dollars(v_line.price_before_discount) || ' → ' || receipt_dollars(v_line.unit_price)
                || coalesce(' · ' || nullif(array_to_string(v_parts, ' + '), ''), '');
      v_saved := v_saved + v_line.qty * (round(v_line.price_before_discount, 2) - round(v_line.unit_price, 2));
    end if;

    v_line_html := v_line_html || format(
      E'<tr style="vertical-align:top;border-bottom:1px solid #cbd5e1;">\n'
      || E'<td style="padding:4px 0;">%s%s</td>\n'
      || E'<td style="padding:4px 0;text-align:right;white-space:nowrap;">%s</td>\n'
      || E'<td style="padding:4px 0;text-align:right;white-space:nowrap;">%s</td>\n'
      || E'<td style="padding:4px 0;text-align:right;white-space:nowrap;">%s</td></tr>\n',
      html_escape(v_label),
      coalesce('<div style="font-size:12px;color:#475569;">' || html_escape(v_note) || '</div>', ''),
      v_line.qty, receipt_dollars(v_line.unit_price), receipt_dollars(v_line.qty * round(v_line.unit_price, 2)));
    v_line_text := v_line_text || v_label
      || (rpad('  ' || v_line.qty || ' × ' || receipt_dollars(v_line.unit_price),
               greatest(char_length('  ' || v_line.qty || ' × ' || receipt_dollars(v_line.unit_price)) + 1,
                        44 - char_length(receipt_dollars(v_line.qty * round(v_line.unit_price, 2)))))
          || receipt_dollars(v_line.qty * round(v_line.unit_price, 2)))
      || case when v_note is not null then array['  ' || v_note] else '{}'::text[] end;
  end loop;

  -- Totals, as the printed receipt shows them.
  if coalesce(v_sale.ticket_discount, 0) <> 0 then
    v_ticket_note := array_to_string(array_remove(array[receipt_discount_words(v_sale.ticket_discount, 'the ticket'),
                                                        nullif(v_sale.ticket_discount_reason, '')], null), ' · ');
  end if;
  if v_saved > 0 then
    v_totals := v_totals || array[[coalesce('You saved (incl. ' || v_ticket_note || ')', 'You saved'),
                                   receipt_dollars(v_saved), '']];
  end if;
  v_totals := v_totals
    || array[['Subtotal', receipt_dollars(v_sale.subtotal), '']]
    || array[[case when v_sale.tax_exempt_id is not null then 'Tax exempt · ' || v_sale.tax_exempt_id
                   else 'Tax (' || trim(trailing '.' from trim(trailing '0' from to_char(coalesce(v_sale.tax_rate, 0), 'FM999990.0000'))) || '%)' end,
              receipt_dollars(v_sale.tax), '']]
    || array[['Total', receipt_dollars(round(v_sale.subtotal, 2) + round(v_sale.tax, 2)), 'strong']];
  for v_payment in
    select sp.method, sp.amount, sp.check_number, b.code as card_code
      from sale_payments sp
      left join gift_card_balance b on b.gift_card_id = sp.gift_card_id
     where sp.sale_id = p_sale_id
     order by sp.created_at, sp.ctid
  loop
    v_totals := v_totals || array[[
      case when v_payment.card_code is not null then 'Gift card ' || mask_gift_card_code(v_payment.card_code)
           when v_payment.method = 'exchange' then 'Exchange credit'
           when v_payment.method = 'check' and v_payment.check_number is not null then 'Check #' || v_payment.check_number
           else coalesce((jsonb_build_object('cash', 'Cash', 'credit', 'Credit', 'gift_card', 'Gift Card',
                                             'store_credit', 'Store Credit', 'check', 'Check') ->> v_payment.method),
                         v_payment.method) end,
      receipt_dollars(v_payment.amount), '']];
  end loop;
  select sum(round(subtotal, 2) + round(tax, 2)) into v_refunded from refunds where sale_id = p_sale_id;
  if coalesce(v_refunded, 0) > 0 then
    v_totals := v_totals || array[['Refunded since', '−' || receipt_dollars(v_refunded), '']];
  end if;

  -- Each gift card the sale loaded or paid with, once, and what's left on it.
  select coalesce(array_agg(array['Gift card ' || mask_gift_card_code(b.code) || ' balance', receipt_dollars(b.balance)]
                            order by u.first_seen), '{}')
    into v_cards
    from (select gift_card_id, min(seen) as first_seen
            from (select sl.gift_card_id, row_number() over (order by sl.created_at, sl.ctid) as seen
                    from sale_lines sl where sl.sale_id = p_sale_id and sl.gift_card_id is not null
                  union all
                  select sp.gift_card_id, 100000 + row_number() over (order by sp.created_at, sp.ctid)
                    from sale_payments sp where sp.sale_id = p_sale_id and sp.gift_card_id is not null) t
           group by gift_card_id) u
    join gift_card_balance b on b.gift_card_id = u.gift_card_id;

  for i in 1 .. coalesce(array_length(v_totals, 1), 0) loop
    v_totals_html := v_totals_html || format(
      E'<tr%s><td style="padding:2px 16px 2px 0;">%s</td><td style="padding:2px 0;text-align:right;white-space:nowrap;">%s</td></tr>\n',
      case when v_totals[i][3] = 'strong' then ' style="font-weight:bold;"' else '' end,
      html_escape(v_totals[i][1]), html_escape(v_totals[i][2]));
  end loop;
  for i in 1 .. coalesce(array_length(v_cards, 1), 0) loop
    v_cards_html := v_cards_html || format(
      E'<tr><td style="padding:2px 16px 2px 0;">%s</td><td style="text-align:right;white-space:nowrap;">%s</td></tr>\n',
      html_escape(v_cards[i][1]), html_escape(v_cards[i][2]));
  end loop;

  v_html := format(
    E'<!doctype html>\n'
    || E'<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Receipt %s</title></head>\n'
    || E'<body style="margin:0;padding:16px;background:#ffffff;color:#000000;font-family:Helvetica,Arial,sans-serif;font-size:14px;">\n'
    || E'<div style="max-width:640px;margin:0 auto;">\n'
    || E'<table role="presentation" style="width:100%%;border-collapse:collapse;margin-bottom:20px;"><tr>\n'
    || E'<td style="vertical-align:top;">%s%s</td>\n'
    || E'<td style="vertical-align:top;text-align:right;">%s</td>\n'
    || E'</tr></table>\n'
    || E'<table style="width:100%%;border-collapse:collapse;">\n'
    || E'<thead><tr style="border-bottom:1px solid #000;text-align:left;">\n'
    || '<th style="padding:4px 0;">Item</th><th style="padding:4px 0;text-align:right;white-space:nowrap;">Qty</th>'
    || '<th style="padding:4px 0;text-align:right;white-space:nowrap;">Each</th>'
    || E'<th style="padding:4px 0;text-align:right;white-space:nowrap;">Total</th>\n'
    || E'</tr></thead>\n<tbody>\n%s</tbody></table>\n'
    || E'<table role="presentation" style="margin:16px 0 0 auto;border-collapse:collapse;">\n%s</table>\n'
    || E'%s%s</div>\n</body></html>',
    v_number,
    coalesce('<h1 style="font-size:22px;margin:0 0 4px;">' || html_escape(nullif(btrim(v_settings.shop_name), '')) || '</h1>', ''),
    (select coalesce(string_agg('<div>' || html_escape(l) || '</div>', '' order by n), '')
       from unnest(v_address) with ordinality as a(l, n)),
    (select string_agg('<div>' || html_escape(l) || '</div>', '' order by n)
       from unnest(v_head) with ordinality as a(l, n)),
    v_line_html,
    v_totals_html,
    case when v_cards_html <> '' then
      E'<table role="presentation" style="margin:12px 0 0 auto;border-collapse:collapse;">\n' || v_cards_html || E'</table>\n'
    else '' end,
    case when v_settings.return_policy is not null or v_settings.receipt_footer is not null then
      E'<div style="border-top:1px solid #000;margin-top:20px;padding-top:12px;">\n'
      || coalesce('<p style="white-space:pre-line;margin:0 0 8px;">' || html_escape(v_settings.return_policy) || E'</p>\n', '')
      || coalesce('<p style="font-weight:bold;margin:0;">' || html_escape(v_settings.receipt_footer) || E'</p>\n', '')
      || E'</div>\n'
    else '' end);

  -- The plain-text copy: label and amount on one 44-character line.
  if nullif(btrim(v_settings.shop_name), '') is not null then
    v_text := v_text || btrim(v_settings.shop_name);
  end if;
  v_text := v_text || v_address || ''::text || v_head || ''::text || v_line_text || ''::text;
  for i in 1 .. coalesce(array_length(v_totals, 1), 0) loop
    v_text := v_text || (rpad(v_totals[i][1], greatest(char_length(v_totals[i][1]) + 1, 44 - char_length(v_totals[i][2])))
                         || v_totals[i][2]);
  end loop;
  if coalesce(array_length(v_cards, 1), 0) > 0 then
    v_text := v_text || ''::text;
    for i in 1 .. array_length(v_cards, 1) loop
      v_text := v_text || (rpad(v_cards[i][1], greatest(char_length(v_cards[i][1]) + 1, 44 - char_length(v_cards[i][2])))
                           || v_cards[i][2]);
    end loop;
  end if;
  if v_settings.return_policy is not null then
    v_text := v_text || ''::text || v_settings.return_policy;
  end if;
  if v_settings.receipt_footer is not null then
    v_text := v_text || ''::text || v_settings.receipt_footer;
  end if;

  return jsonb_build_object('text', array_to_string(v_text, E'\n'), 'html', v_html);
end;
$$;
revoke all on function receipt_email_content(uuid, text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2–3. Queueing: only the sale and the address come from the browser
-- -----------------------------------------------------------------------------
drop function if exists queue_receipt_email(uuid, text, text, text);
create or replace function queue_receipt_email(p_sale_id uuid, p_to text, p_time_zone text default null)
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
  v_content  jsonb;
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

  select count(*) into v_recent
    from notifications
   where sale_id = p_sale_id and kind = 'receipt' and created_at > now() - interval '1 hour';
  if v_recent >= 5 then
    raise exception 'This receipt was already emailed 5 times in the last hour; try again later';
  end if;
  -- The whole shop's hourly cap, counted with the settings row locked so two
  -- sales at once can't both take the last one.
  select coalesce(nullif(btrim(shop_name), ''), 'us') into v_shop from settings where id for update;
  select count(*) into v_recent
    from notifications
   where kind = 'receipt' and created_at > now() - interval '1 hour';
  if v_recent >= 30 then
    raise exception 'The shop has emailed 30 receipts in the last hour; try again later';
  end if;

  v_content := receipt_email_content(p_sale_id, coalesce(p_time_zone, 'UTC'));
  insert into notifications (kind, channel, customer_id, sale_id, to_address, subject, body, html)
  values ('receipt', 'email', v_customer, p_sale_id, v_to,
          format('Your receipt from %s (%s)', coalesce(v_shop, 'us'),
                 upper(left(replace(p_sale_id::text, '-', ''), 8))),
          v_content ->> 'text', v_content ->> 'html')
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function queue_receipt_email(uuid, text, text) from public, anon;
grant execute on function queue_receipt_email(uuid, text, text) to authenticated;
