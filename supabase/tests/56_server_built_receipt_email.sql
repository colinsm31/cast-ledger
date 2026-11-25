-- The receipt email is built on the server, from the sale (0090).
begin;
\ir helpers/setup.psql

select plan(18);

update settings
   set shop_name = 'Ace <Racquets>', shop_address = E'One Main St\n\nSpringfield',
       return_policy = 'Returns in 30 days', receipt_footer = '<a href="http://evil">Click</a>'
 where id;
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-TEST-1234');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 50, 'load');

-- Two strings at $20 (after a 20% promotion and a ticket discount), paid
-- with $10 of gift card and the rest in cash.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table s as select
  record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c1',
              '[{"method":"gift_card","amount":10,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
                {"method":"cash","amount":33.30}]'::jsonb, null) as sale;
grant select on s to authenticated;
select tests.clear_authentication();
update sales set sold_at = '2026-11-24 18:05:00+00', ticket_discount = 5, ticket_discount_reason = 'Loyal'
 where id = (select sale from s);
update sale_lines set price_before_discount = 25, line_discount = 0.2, line_discount_each = 4.5, discount_reason = 'Promo', ticket_discount_each = 0.5
 where sale_id = (select sale from s);

create temp table c as select receipt_email_content((select sale from s)) as content;

-- ---------------------------------------------------------------------------
-- The plain-text copy, line for line as the printed receipt reads
-- ---------------------------------------------------------------------------
select is((select content ->> 'text' from c),
          replace('Ace <Racquets>
One Main St
Springfield

Receipt {N}
Nov 24, 2026, 6:05 PM
Served by staff
Customer: Pat Tester

TestBrand Test String 16 Natural 16
  2 × $20.00                          $40.00
  $25.00 → $20.00 · 20% off · Promo + ticket discount

You saved (incl. $5.00 off the ticket · Loyal) $10.00
Subtotal                              $40.00
Tax (8.25%)                            $3.30
Total                                 $43.30
Gift card ••••1234                    $10.00
Cash                                  $33.30

Gift card ••••1234 balance            $40.00

Returns in 30 days

<a href="http://evil">Click</a>', '{N}', upper(left(replace((select sale from s)::text, '-', ''), 8))),
          'the plain-text receipt has every line of the printed one');

-- ---------------------------------------------------------------------------
-- The HTML: the same layout, every value escaped
-- ---------------------------------------------------------------------------
select ok((select content ->> 'html' from c) like '<!doctype html>%', 'an HTML page');
select ok((select content ->> 'html' from c) like '%<h1 style="font-size:22px;margin:0 0 4px;">Ace &lt;Racquets&gt;</h1><div>One Main St</div><div>Springfield</div>%',
          'the shop''s name and address, escaped');
select ok((select content ->> 'html' from c) like
          '%<td style="padding:4px 0;">TestBrand Test String 16 Natural 16<div style="font-size:12px;color:#475569;">$25.00 → $20.00 · 20% off · Promo + ticket discount</div></td>%',
          'each line with its discount note');
select ok((select content ->> 'html' from c) like '%<tr style="font-weight:bold;"><td style="padding:2px 16px 2px 0;">Total</td>%$43.30</td></tr>%',
          'the total in bold');
select ok((select content ->> 'html' from c) like '%Gift card ••••1234 balance%$40.00%', 'the gift card''s balance left');
select ok((select content ->> 'html' from c) like '%&lt;a href=&quot;http://evil&quot;&gt;Click&lt;/a&gt;%'
          and (select content ->> 'html' from c) !~* '<\s*(a|img|form|script|iframe)\M',
          'a link typed into the settings is shown as text, so the email has no links, images, forms or scripts');

-- ---------------------------------------------------------------------------
-- The time, in the shop's time zone
-- ---------------------------------------------------------------------------
select ok(receipt_email_content((select sale from s), 'America/New_York') ->> 'text' like '%Nov 24, 2026, 1:05 PM%',
          'the sale''s time in the time zone given');
select ok(receipt_email_content((select sale from s), 'Mars/Olympus') ->> 'text' like '%Nov 24, 2026, 6:05 PM%',
          'an unknown time zone is UTC');
select throws_like($$ select receipt_email_content(gen_random_uuid()) $$, 'Unknown sale %', 'the sale must exist');

-- ---------------------------------------------------------------------------
-- The helpers
-- ---------------------------------------------------------------------------
select is(html_escape('<a href="x">&''</a>'), '&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;', 'HTML is escaped');
select is(receipt_discount_words(0.125) || ' / ' || receipt_discount_words(1) || ' / ' || receipt_discount_words(3),
          '12.5% off / 100% off / $3.00 off each', 'discounts read as on the printed receipt');
select is(mask_gift_card_code('1234') || ' ' || mask_gift_card_code('GC-1234'), '1234 ••••1234', 'gift card codes are masked');

-- ---------------------------------------------------------------------------
-- Queueing: only the sale and the address come from the browser
-- ---------------------------------------------------------------------------
select ok(not exists (select 1 from pg_proc where proname = 'queue_receipt_email' and pronargs = 4),
          'the browser can''t send the email''s HTML any more');
create temp table expected as select receipt_email_content((select sale from s), 'America/New_York') as content;
grant select on expected to authenticated;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table q as select queue_receipt_email((select sale from s), 'pat@example.com', 'America/New_York') as id;
grant select on q to authenticated;
select results_eq(
  $$ select body, html from notifications where id = (select id from q) $$,
  $$ select content ->> 'text', content ->> 'html' from expected $$,
  'the queued email is the one built from the sale');

-- At most 30 an hour for the whole shop.
select tests.clear_authentication();
insert into notifications (kind, channel, to_address, subject, body, created_at)
select 'receipt', 'email', 'x' || g || '@example.com', 'R', 'R', now() - interval '30 minutes' from generate_series(1, 29) g;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select queue_receipt_email((select sale from s), 'pat@example.com') $$,
                   'The shop has emailed 30 receipts in the last hour; try again later', 'the 31st in an hour waits');
select tests.clear_authentication();
update notifications set created_at = now() - interval '61 minutes' where kind = 'receipt' and sale_id is null;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select queue_receipt_email((select sale from s), 'pat@example.com') $$, 'an hour later it can go again');

select tests.act_as_anon();
select throws_like($$ select receipt_email_content((select sale from s)) $$, 'permission denied%',
                   'signed-out visitors can''t build receipts');

select * from finish();
rollback;
