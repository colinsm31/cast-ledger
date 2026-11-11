-- Renaming an attribute or an enum value keeps products' values, in that
-- category only, and string jobs keep working (Phase 2A).
begin;
\ir helpers/setup.psql

select plan(34);

-- Test category d1: color (text) and size (enum). d2 has its own color.
insert into attribute_defs (id, category_id, name, value_type, enum_values, sort_order) values
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-0000000000d1', 'color', 'text', null, 0),
  ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-0000000000d1', 'size', 'enum', '["S","M","L"]', 1),
  ('00000000-0000-0000-0000-000000000e03', '00000000-0000-0000-0000-0000000000d2', 'color', 'text', null, 0);

insert into products (id, category_id, name, sell_price, attributes) values
  ('00000000-0000-0000-0000-000000000e11', '00000000-0000-0000-0000-0000000000d1', 'Red Medium', 10, '{"color":"Red","size":"M"}'),
  ('00000000-0000-0000-0000-000000000e12', '00000000-0000-0000-0000-0000000000d1', 'Blue',       10, '{"color":"Blue","finish":"Matte"}'),
  ('00000000-0000-0000-0000-000000000e13', '00000000-0000-0000-0000-0000000000d1', 'Plain',      10, '{}'),
  ('00000000-0000-0000-0000-000000000e14', '00000000-0000-0000-0000-0000000000d2', 'Red Frame',  10, '{"color":"Red"}');

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2');

-- ---------------------------------------------------------------------------
-- Admins only
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'colour', 'text', null, false, null) $$,
  '42501', 'Only an admin can change attributes', 'staff can''t change attributes');

-- A string job entered before any rename, as staff.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000eff', 'x', 'text', null, false, null) $$,
  'Unknown attribute%', 'an unknown attribute is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', '  ', 'text', null, false, null) $$,
  'An attribute needs a name', 'a blank name is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'size', 'text', null, false, null) $$,
  'An attribute named "size" already exists in this category', 'a name already used in the category is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'finish', 'text', null, false, null) $$,
  '1 product still holds an old "finish" value from a deleted attribute: pick another name',
  'a name products still hold a hidden value under is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'colour', 'date', null, false, null) $$,
  'Unknown attribute type "date"', 'an unknown type is refused');

-- ---------------------------------------------------------------------------
-- Renaming an attribute
-- ---------------------------------------------------------------------------
select is(update_attribute_def('00000000-0000-0000-0000-000000000e01', ' colour ', 'text', ' ', true, null),
          2, 'renaming color updates the two products that have one');
select is((select attributes from products where id = '00000000-0000-0000-0000-000000000e11'),
          '{"colour":"Red","size":"M"}'::jsonb, 'the value moves to the new name');
select is((select attributes from products where id = '00000000-0000-0000-0000-000000000e12'),
          '{"colour":"Blue","finish":"Matte"}'::jsonb, 'other keys, hidden ones included, are kept');
select is((select attributes from products where id = '00000000-0000-0000-0000-000000000e13'),
          '{}'::jsonb, 'a product without a value gets none');
select is((select attributes from products where id = '00000000-0000-0000-0000-000000000e14'),
          '{"color":"Red"}'::jsonb, 'another category''s color is untouched');
select is((select name from attribute_defs where id = '00000000-0000-0000-0000-000000000e03'),
          'color', 'and so is its attribute');
select results_eq(
  $$ select name, unit, required from attribute_defs where id = '00000000-0000-0000-0000-000000000e01' $$,
  $$ values ('colour'::text, null::text, true) $$,
  'the name is trimmed, a blank unit is cleared and required is saved');
select is(update_attribute_def('00000000-0000-0000-0000-000000000e01', 'colour', 'text', 'tone', false, null),
          0, 'saving without a rename updates no products');

-- ---------------------------------------------------------------------------
-- Enum values
-- ---------------------------------------------------------------------------
select is(update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false,
                               '["S"," Medium ","L"]', '{"M":"Medium"}'),
          1, 'renaming M updates the product using it');
select is((select attributes->>'size' from products where id = '00000000-0000-0000-0000-000000000e11'),
          'Medium', 'which now holds the new value');
select is((select enum_values from attribute_defs where id = '00000000-0000-0000-0000-000000000e02'),
          '["S","Medium","L"]'::jsonb, 'values are trimmed and saved in order');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false, '["S","L"]') $$,
  '1 product uses "Medium": rename it instead, or change those products first',
  'removing a value a product uses is refused');
select is(update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false, '["S","Medium"]'),
          0, 'removing an unused value is allowed');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false,
                                 '["S"]', '{"Medium":"S"}') $$,
  '"S" is already a value: change the products using "Medium" first', 'renaming onto an existing value is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false,
                                 '["S","Medium","XL"]', '{"L":"XL"}') $$,
  '"L" isn''t one of this attribute''s values', 'renaming a value that isn''t in the list is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false,
                                 '["S","Medium"]', '{"Medium":"XL"}') $$,
  'Renamed value "XL" must be in the new list', 'a renamed value must be in the new list');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false,
                                 '["XS","XL"]', '{"S":"XL","Medium":"XL"}') $$,
  'Two values can''t both be renamed to "XL"', 'two values can''t be renamed to the same one');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false, '["S",""]') $$,
  'Enum values can''t be blank', 'a blank value is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false, '["S","Medium","S "]') $$,
  'Enum value "S" is listed twice', 'a value listed twice is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'enum', null, false, '[]') $$,
  'An enum attribute needs at least one value', 'an empty list is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'colour', 'enum', null, false, '["Red"]') $$,
  '1 product uses "Blue": rename it instead, or change those products first',
  'turning text into an enum that misses a product''s value is refused');
select throws_like(
  $$ select update_attribute_def('00000000-0000-0000-0000-000000000e01', 'colour', 'text', null, false, null, '{"Red":"Crimson"}') $$,
  'Only enum values can be renamed', 'text values can''t be renamed');
select is(update_attribute_def('00000000-0000-0000-0000-000000000e02', 'size', 'text', null, false, '["S"]'),
          0, 'an enum can become text');
select is((select enum_values from attribute_defs where id = '00000000-0000-0000-0000-000000000e02'),
          null::jsonb, 'and its value list is cleared');

-- ---------------------------------------------------------------------------
-- Strings: string jobs keep working after a rename
-- ---------------------------------------------------------------------------
select ok(update_attribute_def(
            (select a.id from attribute_defs a join categories c on c.id = a.category_id
              where c.name = 'Strings' and a.name = 'gauge'),
            'string_gauge', 'enum', null, false, '["15","15L","16","16L","17","18"]') >= 1,
          'renaming the Strings gauge updates the catalog strings');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
             '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  'a string job can still be entered afterwards');
select is((select main_specs from string_jobs where id = '00000000-0000-0000-0000-000000000f02'),
          '{"color":"Natural","string_gauge":"16"}'::jsonb, 'with the renamed spec');
select is((select main_specs from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          '{"color":"Natural","gauge":"16"}'::jsonb, 'an earlier job keeps the details recorded at the time');

select * from finish();
rollback;
