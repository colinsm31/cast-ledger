-- Closing the right day, and keeping it closed (0115).
begin;
\ir helpers/setup.psql

select plan(17);

update settings set time_zone = 'America/Chicago', cash_needs_drawer = true where id;
create function tests.today() returns date language sql as $$ select (now() at time zone 'America/Chicago')::date $$;
create function tests.at(p_day date, p_time time) returns timestamptz language sql as $$
  select (p_day + p_time) at time zone 'America/Chicago' $$;
grant execute on function tests.today(), tests.at(date, time) to authenticated;
create function tests.card_sale_at(p_at timestamptz) returns void language sql as $$
  insert into sales (sold_at, subtotal, tax, tax_rate, payment_method) values (p_at, 20, 1.65, 8.25, 'credit');
$$;

-- Sales on three and on one day ago, nothing two days ago.
select tests.card_sale_at(tests.at(tests.today() - 3, '12:00'));
select tests.card_sale_at(tests.at(tests.today() - 1, '12:00'));

-- Days not yet closed ------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select results_eq($$ select * from unclosed_days() $$,
                  $$ values (tests.today() - 3), (tests.today() - 1), (tests.today()) $$,
                  'days with sales and no close, oldest first, and today');
select lives_ok($$ select close_day(tests.today() - 1) $$, 'a past day is closed by its date');
select results_eq($$ select * from unclosed_days() $$,
                  $$ values (tests.today() - 3), (tests.today()) $$, 'and leaves the list');
select is((select count(*)::int from unclosed_days(2)), 1, 'the list looks back only as far as asked');

-- A close keeps the moments it covers ---------------------------------------------
select close_day(tests.today() - 3);
select tests.clear_authentication();
select throws_ok($$ update settings set time_zone = null where id $$, '22023',
                 'The shop''s time zone can''t be cleared once it''s set', 'the time zone can''t be cleared');
select lives_ok($$ update settings set time_zone = 'Asia/Tokyo' where id $$, 'it can change while no drawer is open');
select throws_like($$ select tests.card_sale_at(tests.at(tests.today() - 3, '12:00')) $$,
                   'That business day (%) has been closed%',
                   'a closed day stays closed for the hours it covered, after the time zone changes');
select lives_ok($$ select tests.card_sale_at(tests.at(tests.today() - 3, '00:00') - interval '1 minute') $$,
                'and a minute before it began isn''t in it');
update settings set time_zone = 'America/Chicago' where id;

-- Daylight saving: 1 Nov 2026 in Chicago ran 25 hours -------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select close_day('2026-11-01') $$, 'the day the clocks went back closes');
select tests.clear_authentication();
select throws_like($$ select tests.card_sale_at('2026-11-02 05:30Z') $$, 'That business day (Sun Nov 1)%',
                   '11:30 PM after the clocks went back is still that day');
select lives_ok($$ select tests.card_sale_at('2026-11-02 06:30Z') $$, 'half past midnight is the next day');

-- A drawer left open from yesterday ------------------------------------------------
insert into drawer_sessions (id, drawer_id, business_day, opened_at, float_counts, float_amount)
values ('00000000-0000-0000-0000-0000000009e1', (select id from drawers where name = 'Main drawer'),
        tests.today() - 2, tests.at(tests.today() - 2, '09:00'), '{"20": 5}', 100);
select throws_ok($$ update settings set time_zone = 'UTC' where id $$, '22023',
                 'Count and close every drawer before changing the time zone',
                 'the time zone can''t change while a drawer is open');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"cash","amount":21.65}]', null) $$,
  'Main drawer was opened on %. Count and close it, then open it again for today',
  'a drawer left open from an earlier day takes no cash today');
select throws_like($$ select record_drawer_movement('00000000-0000-0000-0000-0000000009e1', 'paid_in', 5) $$,
                   'Main drawer was opened on %', 'nor paid-ins');
select close_drawer('00000000-0000-0000-0000-0000000009e1', '{"20": 5}');

-- The lock covers exchanges, string changes and paid-ins -----------------------------
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Pat 1');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":20}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":20}]', null);
create temp table card as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":21.65}]', null) as id;
grant select on card to authenticated;
select close_day(tests.today());
select throws_like(
  $$ select record_exchange((select id from card),
       (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines
         where sale_id = (select id from card)),
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]',
       '00000000-0000-0000-0000-0000000000c1', '[]', '[]', null) $$,
  'That business day (%) has been closed%', 'no exchanges on a closed day');
select tests.clear_authentication();
insert into products (id, category_id, brand, name, sell_price, attributes)
select '00000000-0000-0000-0000-0000000000b5', id, 'TestBrand', 'Premium', 43, '{"color":"Red","gauge":"16"}'
  from categories where name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b5', 10);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53, '[{"method":"credit","amount":23}]') $$,
  'That business day (%) has been closed%', 'no string changes');
select tests.clear_authentication();
select throws_like(
  $$ insert into drawer_movements (drawer_session_id, kind, amount) values ('00000000-0000-0000-0000-0000000009e1', 'paid_in', 1) $$,
  'That business day (%) has been closed%', 'no paid-ins dated a closed day');

select * from finish();
rollback;
