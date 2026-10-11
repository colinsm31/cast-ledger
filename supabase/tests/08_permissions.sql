-- Phase 1C permissions: admin-only configuration, read-only money history,
-- string-job lifecycle columns, and no access at all for signed-out users.
-- Every check goes through the same roles and row-level security the web app
-- (and anyone holding its public key) uses.
begin;
\ir helpers/setup.psql

select plan(35);

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-PERM');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 40, 'load');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame A'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame B');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30);
insert into attribute_defs (category_id, name, value_type) values
  ('00000000-0000-0000-0000-0000000000d1', 'gauge', 'text');

-- ---------------------------------------------------------------------------
-- Staff: shop configuration is read-only
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$ insert into categories (name) values ('Staff category') $$,
  '42501', null, 'staff cannot add a category');
update categories set name = 'Renamed by staff' where id = '00000000-0000-0000-0000-0000000000d1';
select is((select name from categories where id = '00000000-0000-0000-0000-0000000000d1'), 'pgTAP Strings',
          'staff cannot rename a category');
delete from attribute_defs where category_id = '00000000-0000-0000-0000-0000000000d1';
select is((select count(*)::int from attribute_defs where category_id = '00000000-0000-0000-0000-0000000000d1'), 1,
          'staff cannot delete attribute definitions');
update settings set tax_rate = 99 where id;
select is((select tax_rate from settings where id), 8.250::numeric(6,3), 'staff cannot change settings');
select is((select count(*)::int from categories where id = '00000000-0000-0000-0000-0000000000d1'), 1,
          'staff can still read categories');

-- ---------------------------------------------------------------------------
-- Admin: shop configuration is writable
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');

select lives_ok($$ insert into categories (name) values ('Admin category') $$, 'admins can add a category');
update settings set tax_rate = 9 where id;
select is((select tax_rate from settings where id), 9.000::numeric(6,3), 'admins can change settings');
update settings set tax_rate = 8.25 where id;

-- ---------------------------------------------------------------------------
-- Staff: money and stock history can only be written by server functions
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create temp table staff_sale as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
                   null, '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
select isnt((select id from staff_sale), null, 'staff can still ring a sale through record_sale');

select throws_ok($$ insert into sales (subtotal) values (0) $$, '42501', null, 'staff cannot insert a sale directly');
select throws_ok(
  format($$ update sales set subtotal = 0 where id = '%s' $$, (select id from staff_sale)),
  '42501', null, 'staff cannot edit a past sale');
select throws_ok(
  format($$ delete from sale_payments where sale_id = '%s' $$, (select id from staff_sale)),
  '42501', null, 'staff cannot delete a sale''s payments');
select throws_ok(
  $$ delete from sale_lines $$, '42501', null, 'staff cannot delete sale lines');
select throws_ok(
  $$ insert into refunds (sale_id) select id from sales limit 1 $$, '42501', null, 'staff cannot insert a refund directly');
select throws_ok(
  $$ insert into gift_card_txns (gift_card_id, amount) values ('00000000-0000-0000-0000-0000000000e1', 500) $$,
  '42501', null, 'staff cannot load a gift card without a sale');
select throws_ok(
  $$ update gift_cards set customer_id = '00000000-0000-0000-0000-0000000000c1' $$,
  '42501', null, 'staff cannot reassign gift cards directly');
select throws_ok(
  $$ insert into store_credit_txns (customer_id, amount) values ('00000000-0000-0000-0000-0000000000c1', 500) $$,
  '42501', null, 'staff cannot write store credit history directly');
select throws_ok(
  $$ insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b1', 5) $$,
  '42501', null, 'staff cannot write stock history directly');
select throws_ok(
  $$ update product_units set status = 'sold' $$, '42501', null, 'staff cannot change a racquet unit''s status directly');

select lives_ok($$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 5, 8, null, null) $$,
                'staff can still receive stock through receive_stock');
select lives_ok($$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 5, 'goodwill') $$,
                'staff can still issue store credit through add_store_credit');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1'),
          40::numeric, 'staff can read balances through the views');

-- ---------------------------------------------------------------------------
-- Staff: string jobs — content yes, lifecycle no
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into string_jobs (customer_racket_id, status) values ('00000000-0000-0000-0000-0000000000f1', 'complete') $$,
  '%starts as entered and unpaid%', 'a new job cannot start completed');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price, entered_by)
values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 25,
        '00000000-0000-0000-0000-0000000000a2');
select is((select entered_by from string_jobs where id = '00000000-0000-0000-0000-000000000f02'),
          '00000000-0000-0000-0000-0000000000a1'::uuid,
          'a new job is attributed to whoever entered it, whatever the client sends');
select lives_ok(
  $$ update string_jobs set price = 35, notes = 'extra tight', strung_by = 'Alex', main_tension = 55
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'staff can edit a job''s price, notes, stringer and strings');
select throws_ok(
  $$ update string_jobs set status = 'delivered' where id = '00000000-0000-0000-0000-000000000f01' $$,
  '42501', null, 'staff cannot change a job''s status directly');
select throws_ok(
  $$ update string_jobs set completed_by = '00000000-0000-0000-0000-0000000000a2' where id = '00000000-0000-0000-0000-000000000f01' $$,
  '42501', null, 'staff cannot rewrite who completed a job');
select throws_ok(
  $$ delete from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  '42501', null, 'staff cannot delete a string job');

-- ---------------------------------------------------------------------------
-- Signed-out visitors (public anon key only): no access at all
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.act_as_anon();

select throws_ok($$ select * from gift_card_balance $$, '42501', null, 'signed-out visitors cannot list gift card balances');
select throws_ok($$ select * from gift_cards $$, '42501', null, 'signed-out visitors cannot read gift cards');
select throws_ok($$ select * from customers $$, '42501', null, 'signed-out visitors cannot read customers');
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":0}]'::jsonb, null, '[]'::jsonb, null) $$,
  '42501', null, 'signed-out visitors cannot call server functions');

-- ---------------------------------------------------------------------------
-- Structure: definer functions, pinned search paths, invoker views
-- ---------------------------------------------------------------------------
select tests.clear_authentication();

select is(
  (select count(*)::int from pg_proc
    where pronamespace = 'public'::regnamespace and prokind = 'f'
      and not exists (select 1 from unnest(coalesce(proconfig, '{}')) c where c like 'search_path=%')),
  0, 'every public function pins its search_path');
select is(
  (select count(*)::int from pg_proc
    where pronamespace = 'public'::regnamespace and not prosecdef
      and proname in ('record_sale', 'record_refund', 'receive_stock', 'adjust_stock', 'receive_units',
                      'advance_string_job', 'cancel_string_job', 'ensure_gift_card', 'add_store_credit', 'adjust_gift_card')),
  0, 'every function that writes money or stock history runs as the owner');
select is(
  (select count(*)::int from pg_class
    where relnamespace = 'public'::regnamespace and relkind = 'v'
      and not coalesce(reloptions, '{}') @> array['security_invoker=true']),
  0, 'every view uses the reader''s permissions');
select ok(
  not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'trigger functions cannot be called through the API');

select * from finish();
rollback;
