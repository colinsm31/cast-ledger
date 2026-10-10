-- Staff attribution on the remaining write paths, and what happens to it when
-- a staff account is deleted.
begin;
\ir helpers/setup.psql

select plan(7);

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-ATTR');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 40, 'load');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create temp table received as
select receive_stock('00000000-0000-0000-0000-0000000000b1', 5, 8.00, null, 'delivery') as id;
create temp table adjusted as
select adjust_stock('00000000-0000-0000-0000-0000000000b1', -1, 'damaged') as id;

select is((select user_id from inventory_txns where id = (select id from received)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'receive_stock records the staff member');
select is((select user_id from inventory_txns where id = (select id from adjusted)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'adjust_stock records the staff member');

select add_store_credit('00000000-0000-0000-0000-0000000000c1', 15, 'goodwill');
select is((select user_id from store_credit_txns where reason = 'goodwill'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'add_store_credit records the staff member');

select adjust_gift_card('00000000-0000-0000-0000-0000000000e1', -5, 'correction');
select is((select user_id from gift_card_txns where reason = 'correction'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'adjust_gift_card records the staff member');

select tests.clear_authentication();
select is((select user_id from gift_card_txns where reason = 'load'), null::uuid,
          'rows written outside a signed-in session (e.g. imports) have no staff member');

-- Deleting a staff account keeps their records but clears the attribution.
delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1';
select is((select count(*)::int from inventory_txns where id in ((select id from received), (select id from adjusted))),
          2, 'deleting a staff account keeps the records they created');
select is((select user_id from inventory_txns where id = (select id from received)), null::uuid,
          'and clears their attribution');

select * from finish();
rollback;
