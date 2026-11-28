-- Drawer fixes from the 4B review (0113).
begin;
\ir helpers/setup.psql

select plan(12);

update settings set time_zone = 'America/Chicago', cash_needs_drawer = true where id;
insert into drawers (id, name) values ('00000000-0000-0000-0000-0000000009d2', 'Back counter');
create function tests.as_register(p_drawer text) returns void language sql as $$
  select set_config('request.headers', case when p_drawer is null then '{}'
                                            else json_build_object('x-acestock-drawer', p_drawer)::text end, true);
$$;
grant execute on function tests.as_register(text) to authenticated;
create function tests.cash_sale() returns uuid language sql as $$
  select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                     '[{"method":"cash","amount":21.65}]', null);
$$;
grant execute on function tests.cash_sale() to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select open_drawer((select id from drawers where name = 'Main drawer'), '{"20": 5}');

-- Two drawers in use, one open: a register that names none isn't given it --------
select throws_ok($$ select tests.cash_sale() $$, '22023',
                 'Choose this register''s drawer on the Cash drawer screen before taking cash',
                 'with two drawers in use, cash needs the register''s own drawer, not just the open one');
select tests.as_register((select id::text from drawers where name = 'Main drawer'));
select lives_ok($$ select tests.cash_sale() $$, 'the register that names the open drawer takes cash');

-- A drawer taken out of use is ignored ---------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ update drawers set is_active = false where id = '00000000-0000-0000-0000-0000000009d2' $$,
                'a closed drawer can be taken out of use');
select throws_ok($$ update drawers set is_active = false where name = 'Main drawer' $$, '22023',
                 'Count and close Main drawer before taking it out of use',
                 'an open drawer can''t be taken out of use');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select tests.as_register('00000000-0000-0000-0000-0000000009d2');
select lives_ok($$ select tests.cash_sale() $$,
                'a register still naming a drawer out of use falls back to the only drawer in use');
select tests.as_register('00000000-0000-0000-0000-00000000dead');
select lives_ok($$ select tests.cash_sale() $$, 'and so does one naming a drawer that no longer exists');
select is((select count(*)::int from sales where drawer_session_id is not null), 3, 'all three sales are in Main drawer');

-- Exchanges and string changes go to the register's drawer ------------------------
select tests.clear_authentication();
update drawers set is_active = true where id = '00000000-0000-0000-0000-0000000009d2';
insert into products (id, category_id, brand, name, sell_price, attributes)
select '00000000-0000-0000-0000-0000000000b5', id, 'TestBrand', 'Premium', 43, '{"color":"Red","gauge":"16"}'
  from categories where name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b5', 10);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Pat 1');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select open_drawer('00000000-0000-0000-0000-0000000009d2', '{}');
select tests.as_register('00000000-0000-0000-0000-0000000009d2');
create temp table card as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":21.65}]', null) as id;
create temp table ex as
select record_exchange((select id from card),
         (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines
           where sale_id = (select id from card)),
         '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]',
         '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]', '[]', null) as x;
select results_eq(
  $$ select (select drawer_id from drawer_sessions where id = s.drawer_session_id),
            (select drawer_id from drawer_sessions where id = r.drawer_session_id)
       from sales s, refunds r
      where s.id = ((select x from ex)->>'sale_id')::uuid and r.id = ((select x from ex)->>'refund_id')::uuid $$,
  $$ values ('00000000-0000-0000-0000-0000000009d2'::uuid, '00000000-0000-0000-0000-0000000009d2'::uuid) $$,
  'an exchange''s return and sale both go to the register''s drawer');
select is((select cash_sales from drawer_cash_summary(
            (select id from drawer_sessions where drawer_id = '00000000-0000-0000-0000-0000000009d2'))),
          21.65::numeric, 'with the cash it took');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":20}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":20}]', null);
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53, '[{"method":"cash","amount":23}]') $$,
  'a string change paid in cash goes through at the register with its drawer open');
select is((select cash_sales from drawer_cash_summary(
            (select id from drawer_sessions where drawer_id = '00000000-0000-0000-0000-0000000009d2'))),
          44.65::numeric, 'and its cash is in that drawer');

-- No drawers at all ------------------------------------------------------------------
select tests.clear_authentication();
update drawer_sessions set closed_at = now(), counted_counts = '{}', counted_cash = 0 where closed_at is null;
update drawers set is_active = false;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select tests.as_register(null);
select throws_ok($$ select tests.cash_sale() $$, '22023', 'Add a cash drawer in Settings before taking cash',
                 'with no drawer in use, the message says to add one');

select * from finish();
rollback;
