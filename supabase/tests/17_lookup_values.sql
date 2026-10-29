-- Dropdown values staff add on the fly (brands, colors, …) through
-- add_lookup_value: trimmed, never duplicated, never blank, staff only.
begin;
\ir helpers/setup.psql

select plan(9);

select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select is(add_lookup_value(' brand ', '  Test Brand Z  '), 'Test Brand Z',
          'a new value is added, trimmed, and returned');
select is((select count(*)::int from lookup_values where kind = 'brand' and value = 'Test Brand Z'), 1,
          '... and saved under the trimmed kind');
select is(add_lookup_value('brand', 'Test Brand Z'), 'Test Brand Z', 'adding it again returns it');
select is((select count(*)::int from lookup_values where kind = 'brand' and value = 'Test Brand Z'), 1,
          '... without a duplicate');
select is(add_lookup_value('color', 'Test Brand Z'), 'Test Brand Z',
          'the same value can be added under another kind');
select throws_like($$ select add_lookup_value('brand', '   ') $$,
                   '%Lookup value cannot be empty%', 'a blank value is refused');
select throws_like($$ select add_lookup_value(' ', 'Something') $$,
                   '%Lookup kind cannot be empty%', 'a blank kind is refused');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok($$ select add_lookup_value('brand', 'Pending Brand') $$, '42501', null,
                 'an account that isn''t approved can''t add values');

select tests.clear_authentication();
select ok(not has_function_privilege('anon', 'add_lookup_value(text, text)', 'execute'),
          'signed-out visitors can''t call it');

select * from finish();
rollback;
