-- Shop settings have limits (code review #11): tax rate 0–100, stringing labor
-- and the default reorder point not negative.
begin;
\ir helpers/setup.psql

select plan(10);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');

select throws_like(
  $$ update settings set tax_rate = -0.001 where id $$,
  '%Tax rate must be between 0 and 100 (got -0.001)%', 'a negative tax rate is refused');
select throws_like(
  $$ update settings set tax_rate = 100.001 where id $$,
  '%Tax rate must be between 0 and 100%', 'a tax rate over 100 is refused');
select lives_ok($$ update settings set tax_rate = 0 where id $$, 'a 0% tax rate is fine');
select lives_ok($$ update settings set tax_rate = 100 where id $$, '... and so is 100%');
select throws_like(
  $$ update settings set stringing_labor = -0.01 where id $$,
  '%Stringing labor can''t be negative%', 'negative stringing labor is refused');
select lives_ok($$ update settings set stringing_labor = 0 where id $$, 'no stringing labor is fine');
select throws_like(
  $$ update settings set default_reorder_point = -1 where id $$,
  '%Default reorder point can''t be negative%', 'a negative default reorder point is refused');
select lives_ok($$ update settings set default_reorder_point = null where id $$, 'no default reorder point is fine');

select lives_ok($$ update settings set tax_rate = 8.875, stringing_labor = 18, default_reorder_point = 2 where id $$,
                'an admin can save valid settings');
select tests.clear_authentication();
select ok(not has_function_privilege('authenticated', 'guard_settings()', 'execute'),
          'the settings guard is internal');

select * from finish();
rollback;
