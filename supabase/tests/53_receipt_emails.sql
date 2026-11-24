-- Emailing a sale's receipt (Phase 3E).
begin;
\ir helpers/setup.psql

select plan(10);

update settings set shop_name = 'Ace Racquets' where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table s as select
  record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]'::jsonb, null) as sale;
grant select on s to authenticated;

select throws_like($$ select queue_receipt_email((select sale from s), 'not-an-address') $$,
                   'Enter a valid email address for the receipt', 'a valid address is needed');
select throws_like($$ select queue_receipt_email(gen_random_uuid(), 'sam@example.com') $$,
                   'Unknown sale %', 'the sale must exist');
create temp table q as select queue_receipt_email((select sale from s), ' sam@example.com ') as id;
grant select on q to authenticated;
select results_eq(
  $$ select kind, channel, customer_id, to_address, subject, body like 'Ace Racquets%', html like '<!doctype html>%',
            status, created_by
       from notifications where id = (select id from q) $$,
  $$ select 'receipt'::text, 'email'::text, '00000000-0000-0000-0000-0000000000c1'::uuid, 'sam@example.com'::text,
            'Your receipt from Ace Racquets (' || upper(left(replace((select sale from s)::text, '-', ''), 8)) || ')',
            true, true, 'queued'::text, '00000000-0000-0000-0000-0000000000a1'::uuid $$,
  'the receipt is queued for the sale''s customer, with the subject set by the server');

-- The sender claims it by its sale.
select tests.clear_authentication();
select is((select count(*)::int from claim_notifications(p_sale_id => (select sale from s))), 1,
          'the sender claims it by its sale');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Five an hour per sale.
select queue_receipt_email((select sale from s), 'sam@example.com') from generate_series(1, 4);
select is((select count(*)::int from notifications where sale_id = (select sale from s)), 5, 'five receipts queued');
select throws_like($$ select queue_receipt_email((select sale from s), 'sam@example.com') $$,
                   'This receipt was already emailed 5 times in the last hour; try again later', 'the sixth waits');
select tests.clear_authentication();
update notifications set created_at = now() - interval '61 minutes' where sale_id = (select sale from s);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select queue_receipt_email((select sale from s), 'sam@example.com') $$,
                'an hour later it can go again');

-- A receipt that failed goes again to the same address (no opt-in needed).
select tests.clear_authentication();
update notifications set status = 'failed' where id = (select id from q);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(resend_notification((select id from q)), (select id from q), 'a failed receipt is sent again');
select is((select to_address from notifications where id = (select id from q)), 'sam@example.com', 'to the same address');

select tests.act_as_anon();
select throws_like($$ select queue_receipt_email((select sale from s), 'sam@example.com') $$,
                   'permission denied%', 'signed-out visitors can''t email receipts');

select * from finish();
rollback;
