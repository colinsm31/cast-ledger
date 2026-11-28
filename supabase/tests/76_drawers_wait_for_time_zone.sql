-- Cash isn't held up before the shop's time zone is set (0114).
begin;
\ir helpers/setup.psql

select plan(3);

update settings set time_zone = null, cash_needs_drawer = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  'before the time zone is set, cash is taken with no drawer');
select is((select drawer_session_id from sales), null::uuid, 'in no drawer');

select tests.clear_authentication();
update settings set time_zone = 'America/Chicago' where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  '22023', 'Open Main drawer on the Cash drawer screen before taking cash',
  'once it''s set, cash needs the drawer open');

select * from finish();
rollback;
