-- Lending demo frames and checking them back in (Phase 3C).
begin;
\ir helpers/setup.psql

select plan(33);

-- Two frames in the demo fleet, one in stock.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["DM-1", "DM-2", "DM-3"]');
create temp table u as
  select (select id from product_units where barcode = 'DM-1') as one,
         (select id from product_units where barcode = 'DM-2') as two,
         (select id from product_units where barcode = 'DM-3') as three;
grant select on u to authenticated;
select set_unit_status((select one from u), 'demo', 'Demo fleet');
select set_unit_status((select two from u), 'demo', 'Demo fleet');

-- ---------------------------------------------------------------------------
-- Lending
-- ---------------------------------------------------------------------------
create temp table l as
  select check_out_demo((select one from u), '00000000-0000-0000-0000-0000000000c1', null, ' Card on file ', null) as first;
grant select on l to authenticated;

select results_eq(
  $$ select status, customer_id from product_units where id = (select one from u) $$,
  $$ values ('assigned'::text, '00000000-0000-0000-0000-0000000000c1'::uuid) $$,
  'a lent frame is assigned to the customer');
select results_eq(
  $$ select loan_number >= 1001, deposit_note, out_by, back_at is null from demo_loans where id = (select first from l) $$,
  $$ values (true, 'Card on file'::text, '00000000-0000-0000-0000-0000000000a1'::uuid, true) $$,
  'the loan has a number, the deposit note and who lent it');
select ok((select due_back_at between now() + interval '3 days' - interval '1 minute' and now() + interval '3 days'
             from demo_loans where id = (select first from l)),
          'it''s due back after the shop''s demo loan days (3 by default)');
select is(
  (select reason from unit_status_changes where product_unit_id = (select one from u) and to_status = 'assigned'),
  (select 'Lent to Pat Tester (D' || loan_number || ')' from demo_loans where id = (select first from l)),
  'the frame''s history says who it was lent to, with the loan number');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'), 1::numeric,
          'only the frame in stock counts as on hand');

select throws_like($$ select check_out_demo((select one from u), '00000000-0000-0000-0000-0000000000c1') $$,
                   'This frame is already out on demo', 'a frame can''t be lent twice');
select throws_like($$ select check_out_demo((select three from u), '00000000-0000-0000-0000-0000000000c1') $$,
                   'Only a frame in the demo fleet can be lent (this one is in stock)', 'only demo frames are lent');
select throws_like($$ select check_out_demo((select two from u), '00000000-0000-0000-0000-00000000dead') $$,
                   'Pick the customer borrowing the demo', 'a demo is lent to a customer on file');
select throws_like($$ select check_out_demo((select two from u), '00000000-0000-0000-0000-0000000000c1', now() - interval '1 hour') $$,
                   'The due time has to be in the future', 'the due time is in the future');
select throws_like($$ select check_out_demo((select two from u), '00000000-0000-0000-0000-0000000000c1', now() + interval '91 days') $$,
                   'A demo can be lent for at most 90 days', 'and at most 90 days away');
select throws_like($$ select check_out_demo((select two from u), '00000000-0000-0000-0000-0000000000c1', null, repeat('x', 201)) $$,
                   'Keep each note to 200 characters', 'notes are at most 200 characters');
select throws_like($$ select check_out_demo('00000000-0000-0000-0000-00000000dead', '00000000-0000-0000-0000-0000000000c1') $$,
                   'Unknown unit %', 'an unknown frame is refused');

-- A frame out on demo can't be sold, moved or returned.
select throws_like(
  $$ select record_sale(jsonb_build_array(jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                          'product_unit_id', (select one from u), 'qty', 1, 'unit_price', 250)),
                        null, '[{"method":"cash","amount":270.63}]'::jsonb, null) $$,
  '%not in stock (status assigned)%', 'a frame out on demo can''t be sold');
select throws_like($$ select set_unit_status((select one from u), 'retired', 'Lost') $$,
                   'This frame is assigned, so it can''t be moved here', 'or moved without checking it in');

-- Admin sets a longer default; a chosen due time is kept.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update settings set demo_loan_days = 7 where id;
select throws_like($$ update settings set demo_loan_days = 61 where id $$, '%ck_settings_demo_loan_days%',
                   'demo loan days are at most 60');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table l2 as select check_out_demo((select two from u), '00000000-0000-0000-0000-0000000000c1',
                                    date_trunc('minute', now()) + interval '2 days', null, 'Wants to try the 16x19') as second;
select is((select due_back_at from demo_loans where product_unit_id = (select two from u)),
          date_trunc('minute', now()) + interval '2 days', 'a due time staff pick is kept');

-- ---------------------------------------------------------------------------
-- A new due time
-- ---------------------------------------------------------------------------
select lives_ok($$ select set_demo_due((select first from l), now() + interval '5 days') $$, 'a loan can be extended');
select throws_like($$ select set_demo_due((select first from l), now() - interval '1 day') $$,
                   'The due time has to be in the future', 'but not into the past');
select throws_like($$ select set_demo_due('00000000-0000-0000-0000-00000000dead', now() + interval '1 day') $$,
                   'Unknown demo loan %', 'an unknown loan is refused');

-- ---------------------------------------------------------------------------
-- Checking in
-- ---------------------------------------------------------------------------
select is(check_in_demo((select first from l)), 'demo', 'a demo comes back to the demo fleet');
select results_eq(
  $$ select status, customer_id from product_units where id = (select one from u) $$,
  $$ values ('demo'::text, null::uuid) $$, 'and is nobody''s again');
select results_eq(
  $$ select back_status, back_by, back_at is not null from demo_loans where id = (select first from l) $$,
  $$ values ('demo'::text, '00000000-0000-0000-0000-0000000000a1'::uuid, true) $$,
  'the loan records who checked it in');
select is(
  (select reason from unit_status_changes where product_unit_id = (select one from u) and from_status = 'assigned'),
  (select 'Back from D' || loan_number from demo_loans where id = (select first from l)),
  'its history records the return');
select throws_like($$ select check_in_demo((select first from l)) $$, 'Demo D% has already been checked in',
                   'a demo can''t be checked in twice');
select throws_like($$ select set_demo_due((select first from l), now() + interval '1 day') $$,
                   'Demo D% has already been checked in', 'or extended once it''s back');

savepoint no_reason;
select lives_ok(
  $$ select check_in_demo((select id from demo_loans where product_unit_id = (select two from u) and back_at is null), 'retired') $$,
  'a damaged demo can be retired with no reason (0093)');
rollback to savepoint no_reason;
select throws_like($$ select check_in_demo('00000000-0000-0000-0000-00000000dead', 'in_stock') $$,
                   'A demo comes back to the demo fleet or is retired (not "in_stock")', 'it goes back to demo or is retired');
select is(check_in_demo((select id from demo_loans where product_unit_id = (select two from u) and back_at is null),
                        'retired', 'Cracked at the throat'), 'retired', 'a damaged demo is retired');
select is(
  (select reason from unit_status_changes where product_unit_id = (select two from u) and to_status = 'retired'),
  (select 'Cracked at the throat (back from D' || loan_number || ')' from demo_loans where product_unit_id = (select two from u)),
  'with the reason in its history');

-- ---------------------------------------------------------------------------
-- Who can do what
-- ---------------------------------------------------------------------------
select throws_like($$ insert into demo_loans (product_unit_id, customer_id, due_back_at)
                      values ((select one from u), '00000000-0000-0000-0000-0000000000c1', now() + interval '1 day') $$,
                   '%permission denied%', 'staff can''t write loans directly');

select tests.clear_authentication();
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok($$ select check_out_demo((select one from u), '00000000-0000-0000-0000-0000000000c1') $$,
                 '42501', null, 'an account waiting for approval can''t lend demos');
select throws_ok($$ select check_in_demo((select first from l)) $$,
                 '42501', null, 'or check them in');

select tests.act_as_anon();
select throws_like($$ select check_out_demo('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c1') $$,
                   '%permission denied%', 'visitors can''t lend demos');

select * from finish();
rollback;
