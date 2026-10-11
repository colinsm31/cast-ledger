-- Only approved staff can use the shop's data (code review #1, #32).
-- A self-signed-up account starts 'pending' and can't read or write anything
-- except its own profile — including through the server functions.
begin;
\ir helpers/setup.psql

select plan(26);

select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-ACCESS');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 40, 'load');

-- ---------------------------------------------------------------------------
-- New accounts start pending
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-0000000000a4', 'self-signup@test.local', 'authenticated', 'authenticated');
select is((select role from profiles where id = '00000000-0000-0000-0000-0000000000a4'), 'pending',
          'a new account (e.g. a self sign-up) starts as pending, not staff');

-- ---------------------------------------------------------------------------
-- A pending account can read nothing but its own profile
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');

select is((select role from profiles where id = '00000000-0000-0000-0000-0000000000a3'), 'pending',
          'a pending account can see that it is pending');
select is((select count(*)::int from profiles), 1, 'a pending account cannot list other staff');
select is((select count(*)::int from customers), 0, 'a pending account cannot read customers');
select is((select count(*)::int from products), 0, 'a pending account cannot read products');
select is((select count(*)::int from sales), 0, 'a pending account cannot read sales');
select is((select count(*)::int from gift_cards), 0, 'a pending account cannot read gift cards');
select is((select count(*)::int from gift_card_balance), 0, 'a pending account cannot read gift card balances');
select is((select count(*)::int from settings), 0, 'a pending account cannot read settings');
select is((select count(*)::int from search_customers('Tester')), 0, 'customer search returns nothing to a pending account');
select is((select kind from resolve_barcode('GC-ACCESS')), 'none', 'barcode lookup finds nothing for a pending account');

-- ---------------------------------------------------------------------------
-- … and can write nothing, directly or through the server functions
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into customers (first_name, last_name) values ('Sneaky', 'Signup') $$,
  '42501', null, 'a pending account cannot add a customer');
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":0}]'::jsonb, null, '[]'::jsonb, null) $$,
  '42501', null, 'a pending account cannot ring a sale');
select throws_ok(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e1', 500, 'free money') $$,
  '42501', null, 'a pending account cannot adjust a gift card');
select throws_ok(
  $$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 500, 'free money') $$,
  '42501', null, 'a pending account cannot issue store credit');
select throws_ok(
  $$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -10, 'shrink') $$,
  '42501', null, 'a pending account cannot adjust stock');
select throws_ok(
  $$ select ensure_gift_card('GC-NEW-PENDING', null) $$,
  '42501', null, 'a pending account cannot create gift cards');
select throws_ok(
  $$ select set_user_role('00000000-0000-0000-0000-0000000000a3', 'staff') $$,
  'P0001', 'Only an admin can change roles', 'a pending account cannot approve itself');

select tests.clear_authentication();
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1'), 40::numeric,
          'nothing a pending account tried changed any balance');

-- ---------------------------------------------------------------------------
-- Admins approve and remove access
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select set_user_role('00000000-0000-0000-0000-0000000000a3', 'staff') $$,
  'P0001', 'Only an admin can change roles', 'staff cannot approve accounts');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select set_user_role('00000000-0000-0000-0000-0000000000a3', 'staff') $$,
                'an admin approves a pending account as staff');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select is((select count(*)::int from customers), 1, 'once approved, the account can read customers');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select set_user_role('00000000-0000-0000-0000-0000000000a1', 'pending') $$,
                'an admin can remove a staff member''s access');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from customers), 0, 'removed staff lose access immediately');

-- ---------------------------------------------------------------------------
-- The last admin can't be demoted, even to pending
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ select set_user_role('00000000-0000-0000-0000-0000000000a2', 'pending') $$,
  'P0001', 'Cannot demote the last admin', 'the last admin cannot remove their own access');
select throws_ok(
  $$ select set_user_role('00000000-0000-0000-0000-0000000000a2', 'manager') $$,
  'P0001', 'Invalid role "manager"', 'unknown roles are rejected');

select * from finish();
rollback;
