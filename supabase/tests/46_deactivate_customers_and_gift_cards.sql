-- Inactive customers and gift cards (Phase 3D): kept in history, refused at
-- the register.
begin;
\ir helpers/setup.psql

select plan(35);

insert into customers (id, first_name, last_name) values
  ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Gone'),
  ('00000000-0000-0000-0000-0000000000c3', 'Jo', 'Busy');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c2', 'Sam 1'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c3', 'Jo 1');
insert into store_credit_txns (customer_id, amount, reason) values ('00000000-0000-0000-0000-0000000000c2', 15, 'fixture');
insert into gift_cards (id, code, customer_id) values
  ('00000000-0000-0000-0000-0000000000e1', 'GC-LOST', '00000000-0000-0000-0000-0000000000c2');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 40, 'load');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- A sale to Sam before they go inactive, to refund later.
create temp table s as select
  record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c2', '[{"method":"cash","amount":21.65}]'::jsonb, null) as sam;
grant select on s to authenticated;

-- ---------------------------------------------------------------------------
-- Turning a customer off
-- ---------------------------------------------------------------------------
select throws_like($$ update customers set is_active = false where id = '00000000-0000-0000-0000-0000000000c2' $$,
                   'Make a record inactive or active again from its page (it keeps the reason)',
                   'staff can''t flip the flag directly');
savepoint no_reason;
select lives_ok(
  $$ select set_customer_active('00000000-0000-0000-0000-0000000000c2', false, '  ') $$,
  'no reason is needed (0093)');
rollback to savepoint no_reason;
select throws_like($$ select set_customer_active('00000000-0000-0000-0000-0000000000c2', false, repeat('x', 201)) $$,
                   'Keep the reason to 200 characters', 'of at most 200 characters');
select lives_ok($$ select set_customer_active('00000000-0000-0000-0000-0000000000c2', false, ' Moved away ') $$,
                'Sam is made inactive');
select results_eq(
  $$ select is_active, deactivated_reason, deactivated_by, deactivated_at is not null from customers
      where id = '00000000-0000-0000-0000-0000000000c2' $$,
  $$ values (false, 'Moved away'::text, '00000000-0000-0000-0000-0000000000a1'::uuid, true) $$,
  'with the reason, who and when');
select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c2'),
          15::numeric, 'his store credit stays');

-- Jo has a job open.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension)
values ('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000f3',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50);
select throws_like($$ select set_customer_active('00000000-0000-0000-0000-0000000000c3', false, 'Duplicate') $$,
                   'This customer has a string job open: settle it before making them inactive',
                   'a customer with a job open stays active');

-- ---------------------------------------------------------------------------
-- An inactive customer can't be used
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
                        '00000000-0000-0000-0000-0000000000c2', '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'Sam Gone is inactive, so they can''t be put on a sale: make them active again first', 'no sale to Sam');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension)
     values ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 50, 50) $$,
  'Sam Gone is inactive, so they can''t have a new string job%', 'no new string job');
select throws_like($$ select add_store_credit('00000000-0000-0000-0000-0000000000c2', 5, 'Goodwill') $$,
                   'Sam Gone is inactive, so they can''t use store credit%', 'no store credit added');
select throws_like(
  $$ select record_refund((select sam from s),
       jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select sam from s)), 'qty', 1)),
       '[{"method":"store_credit","amount":21.65}]'::jsonb, null, null, 'Asked for credit') $$,
  'Sam Gone is inactive, so they can''t use store credit%', 'an old sale isn''t refunded to his store credit');
select lives_ok(
  $$ select record_refund((select sam from s),
       jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select sam from s)), 'qty', 1)),
       '[{"method":"cash","amount":21.65}]'::jsonb, null, null) $$,
  'but it can be refunded in cash');

select lives_ok($$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["DEMO-46"]') $$, 'a frame comes in');
select lives_ok($$ select set_unit_status((select id from product_units where barcode = 'DEMO-46'), 'demo', 'Demo fleet') $$,
                'a demo frame');
select throws_like(
  $$ select check_out_demo((select id from product_units where barcode = 'DEMO-46'), '00000000-0000-0000-0000-0000000000c2',
                           now() + interval '2 days', null, null) $$,
  'Sam Gone is inactive, so they can''t borrow a demo%', 'no demo for Sam');

select is((select count(*)::int from search_customers('Gone')), 0, 'the register''s search leaves Sam out');
select is((select count(*)::int from search_customers('Gone', 8, true)), 1, 'the customer list can still find them');
select is((select count(*)::int from sales where customer_id = '00000000-0000-0000-0000-0000000000c2'), 1,
          'their sales stay in history');

-- ---------------------------------------------------------------------------
-- And back again
-- ---------------------------------------------------------------------------
select lives_ok($$ select set_customer_active('00000000-0000-0000-0000-0000000000c2', true) $$, 'Sam is made active again');
select results_eq(
  $$ select is_active, deactivated_reason, deactivated_at from customers where id = '00000000-0000-0000-0000-0000000000c2' $$,
  $$ values (true, null::text, null::timestamptz) $$, 'the reason is cleared');

-- ---------------------------------------------------------------------------
-- A lost gift card
-- ---------------------------------------------------------------------------
savepoint no_reason;
select lives_ok(
  $$ select set_gift_card_active('00000000-0000-0000-0000-0000000000e1', false, null) $$,
  'nor for a card (0093)');
rollback to savepoint no_reason;
select lives_ok($$ select set_gift_card_active('00000000-0000-0000-0000-0000000000e1', false, 'Lost') $$,
                'the lost card is made inactive');
select results_eq(
  $$ select is_active, balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1' $$,
  $$ values (false, 40::numeric) $$, 'the register sees it inactive, its balance kept');
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
       '[{"method":"gift_card","amount":20,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
         {"method":"cash","amount":1.65}]'::jsonb, null) $$,
  'Gift card GC-LOST is inactive, so it can''t be used: make it active again first', 'it can''t be spent');
select throws_like(
  $$ select record_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":10}]'::jsonb, null,
       '[{"method":"cash","amount":10}]'::jsonb, null) $$,
  'Gift card GC-LOST is inactive%', 'or loaded');
select throws_like($$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e1', -5, 'Fix') $$,
                   'Gift card GC-LOST is inactive%', 'or adjusted');
select throws_like($$ insert into gift_cards (code, is_active) values ('GC-NEW', false) $$,
                   '%permission denied%', 'staff can''t write cards directly');

-- An unused load still comes back off a card made inactive (0075).
select tests.clear_authentication();
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e2', 'GC-46B');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table load_sale as select record_sale(
  '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e2","qty":1,"unit_price":25}]'::jsonb, null,
  '[{"method":"cash","amount":25}]'::jsonb, null) as id;
grant select on load_sale to authenticated;
select lives_ok($$ select set_gift_card_active('00000000-0000-0000-0000-0000000000e2', false, 'Loaded by mistake') $$,
                'a card loaded by mistake is made inactive');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ select record_refund((select id from load_sale),
       jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select id from load_sale)), 'qty', 1)),
       '[{"method":"cash","amount":25}]'::jsonb, 'Loaded by mistake', null) $$,
  'its unused load is refunded all the same');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e2'), 0::numeric,
          'leaving the inactive card empty');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- A found card is made active again and can be spent.
select lives_ok($$ select set_gift_card_active('00000000-0000-0000-0000-0000000000e1', true) $$,
                'the lost card is found and made active again');
select results_eq(
  $$ select is_active, deactivated_reason from gift_cards where id = '00000000-0000-0000-0000-0000000000e1' $$,
  $$ values (true, null::text) $$, 'its reason is cleared');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
       '[{"method":"gift_card","amount":20,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
         {"method":"cash","amount":1.65}]'::jsonb, null) $$,
  'and it can be spent again');

-- A demo out stops a customer being made inactive.
select check_out_demo((select id from product_units where barcode = 'DEMO-46'), '00000000-0000-0000-0000-0000000000c1',
                      now() + interval '2 days', null, null);
select throws_like($$ select set_customer_active('00000000-0000-0000-0000-0000000000c1', false, 'Moved away') $$,
                   'This customer has a demo out: settle it before making them inactive',
                   'a customer with a demo out stays active until it''s back');

insert into customers (id, first_name, last_name, is_active, deactivated_reason)
values ('00000000-0000-0000-0000-0000000000c4', 'New', 'Person', false, 'Sneaky');
select results_eq($$ select is_active, deactivated_reason from customers where id = '00000000-0000-0000-0000-0000000000c4' $$,
                  $$ values (true, null::text) $$, 'a new customer starts active');

select * from finish();
rollback;
