-- Finding items at the register by name, and quick picks (Phase 2D).
begin;
\ir helpers/setup.psql

select plan(11);

-- b1: TestBrand Test String 16, Natural, gauge 16, UPC 012345678905.
-- b2: TestBrand Test Racquet 100.
insert into products (id, category_id, brand, name, sell_price, sku, attributes, is_active) values
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000d1', 'Wilson', 'Pro Overgrip', 3,
   'OG-WHT-3', '{"color":"White"}', true),
  ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000d1', 'Wilson', 'Old 50% Overgrip', 2,
   null, '{}', false);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select results_eq($$ select name from search_products('test string') $$, $$ values ('Test String 16') $$,
                  'every word must match');
select results_eq($$ select name from search_products('testbrand natural 16') $$, $$ values ('Test String 16') $$,
                  'words can match the brand, name or an attribute value');
select results_eq($$ select name from search_products('og-wht') $$, $$ values ('Pro Overgrip') $$, 'the SKU matches');
select results_eq($$ select name from search_products('5678905') $$, $$ values ('Test String 16') $$,
                  'part of the barcode matches');
select results_eq($$ select name from search_products('testbrand') $$,
                  $$ values ('Test Racquet 100'), ('Test String 16') $$, 'results are by brand, then name');
select is_empty($$ select * from search_products('overgrip 50%') $$, 'inactive products aren''t found');
select is_empty($$ select * from search_products('%') $$, 'wildcards are matched literally');
select is_empty($$ select * from search_products('   ') $$, 'a blank search finds nothing');
select is((select count(*)::int from search_products('test', 1)), 1, 'the limit is kept');

update products set quick_pick = true where id = '00000000-0000-0000-0000-0000000000b5';
select results_eq($$ select name from products where quick_pick and is_active $$, $$ values ('Pro Overgrip') $$,
                  'staff can mark a quick pick');

select tests.act_as_anon();
select throws_ok($$ select * from search_products('test') $$, '42501', null, 'signed-out visitors can''t search');

select * from finish();
rollback;
