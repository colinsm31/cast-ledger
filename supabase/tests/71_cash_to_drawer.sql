-- Cash taken or given back goes to a drawer; expected vs counted (0109).
begin;
\ir helpers/setup.psql

select plan(17);

update settings set time_zone = 'America/Chicago', cash_needs_drawer = true, accept_checks = true where id;
insert into drawers (id, name) values ('00000000-0000-0000-0000-0000000009d2', 'Back counter');
create function tests.as_register(p_drawer uuid) returns void language sql as $$
  select set_config('request.headers', case when p_drawer is null then '{}'
                                            else json_build_object('x-acestock-drawer', p_drawer)::text end, true);
$$;
grant execute on function tests.as_register(uuid) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- No drawer open ------------------------------------------------------------------
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  '22023', 'Open the cash drawer on the Cash drawer screen before taking cash',
  'with no drawer open, cash is refused');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"credit","amount":21.65}]', null) $$,
  'card sales go through with no drawer open');
select is((select drawer_session_id from sales), null::uuid, 'and belong to no drawer');

-- One drawer open: cash goes to it with no header --------------------------------
select open_drawer((select id from drawers where name = 'Main drawer'), '{"20": 5}');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]', null,
                        '[{"method":"cash","amount":43.30}]', null) $$,
  'with one drawer open, cash goes to it');
select is((select count(*)::int from sales where drawer_session_id = (select id from drawer_sessions)), 1,
          'the sale is in the open drawer');

-- A refund and a check -------------------------------------------------------------
select lives_ok(
  $$ select record_refund((select id from sales where drawer_session_id is not null),
                          (select jsonb_build_array(jsonb_build_object('sale_line_id', sl.id, 'qty', 1))
                             from sale_lines sl join sales s on s.id = sl.sale_id where s.drawer_session_id is not null),
                          '[{"method":"cash","amount":21.65}]', null, null) $$,
  'cash given back goes to the drawer too');
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                   '[{"method":"check","amount":21.65,"check_number":"1042"}]', null);
select results_eq(
  $$ select float_amount, cash_sales, cash_refunds, expected_cash, check_sales, check_refunds
       from drawer_cash_summary((select id from drawer_sessions)) $$,
  $$ values (100.00::numeric, 43.30::numeric, 21.65::numeric, 121.65::numeric, 21.65::numeric, 0::numeric) $$,
  'expected cash is float + cash taken − cash given back; checks are listed apart');

-- Two drawers open: the register says which ---------------------------------------
select open_drawer('00000000-0000-0000-0000-0000000009d2', '{}');
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  '22023', 'Choose this register''s drawer on the Cash drawer screen before taking cash',
  'with two drawers open and none chosen, cash is refused');
select tests.as_register('00000000-0000-0000-0000-0000000009d2');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  'the register''s chosen drawer takes the cash');
select is((select cash_sales from drawer_cash_summary(
            (select id from drawer_sessions where drawer_id = '00000000-0000-0000-0000-0000000009d2'))),
          21.65::numeric, 'into that drawer only');
select tests.clear_authentication();
select set_config('request.headers', '{"x-acestock-drawer":"not-a-uuid"}', true);
select is(requested_drawer_id(), null::uuid, 'a header that isn''t a drawer id is ignored');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Closing: expected vs counted ---------------------------------------------------
select tests.as_register(null);
select close_drawer((select id from drawer_sessions where drawer_id = '00000000-0000-0000-0000-0000000009d2'), '{"20": 1}');
select tests.as_register('00000000-0000-0000-0000-0000000009d2');
select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  '22023', 'Open Back counter on the Cash drawer screen before taking cash',
  'a register whose drawer is closed is told to open it');
select tests.as_register(null);
select close_drawer((select id from drawer_sessions where drawer_id = (select id from drawers where name = 'Main drawer')),
                    '{"20": 6, "1": 1, "0.25": 2}');
select throws_ok(
  $$ select record_refund((select id from sales where payment_method = 'credit' limit 1),
                          (select jsonb_build_array(jsonb_build_object('sale_line_id', sl.id, 'qty', 1))
                             from sale_lines sl join sales s on s.id = sl.sale_id
                            where s.payment_method = 'credit' limit 1),
                          '[{"method":"cash","amount":21.65}]', null, null) $$,
  '22023', 'Open the cash drawer on the Cash drawer screen before giving cash back',
  'with every drawer closed, cash can''t be given back either');
select results_eq(
  $$ select expected_cash, counted_cash, counted_cash - expected_cash from drawer_sessions
      where drawer_id = (select id from drawers where name = 'Main drawer') $$,
  $$ values (121.65::numeric, 121.50::numeric, -0.15::numeric) $$,
  'the close saves expected and counted cash: 15 cents short');
select is((select expected_cash from drawer_sessions where drawer_id = '00000000-0000-0000-0000-0000000009d2'),
          21.65::numeric, 'each drawer has its own expected cash');

-- The check can be turned off -------------------------------------------------------
select tests.clear_authentication();
update settings set cash_needs_drawer = false where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  'with the setting off, cash is taken with no drawer open');
select is((select count(*)::int from sales where drawer_session_id is null and payment_method = 'cash'), 1,
          'and belongs to no drawer');

select * from finish();
rollback;
