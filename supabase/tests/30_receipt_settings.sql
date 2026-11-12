-- The receipt text in settings: optional, trimmed, limited in length; staff
-- can read it and only an admin can change it (Phase 2C).
begin;
\ir helpers/setup.psql

select plan(8);

select lives_ok(
  $$ update settings set shop_name = 'Ace Racquets', shop_address = E'12 Court St\nSpringfield · (555) 123-4567',
                         return_policy = 'Unstrung racquets within 30 days.', receipt_footer = 'Thanks for playing!' where id $$,
  'the receipt text can be set');
select throws_ok($$ update settings set shop_name = ' Ace ' where id $$, '23514', null, 'text is stored trimmed');
select throws_ok($$ update settings set shop_name = '' where id $$, '23514', null, 'blank text is stored as none');
select throws_ok($$ update settings set return_policy = repeat('x', 1001) where id $$, '23514', null,
                 'a return policy over 1000 characters is refused');
select lives_ok($$ update settings set receipt_footer = null where id $$, 'each line is optional');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select shop_name from settings), 'Ace Racquets', 'staff can read the receipt text');
update settings set shop_name = 'Not Ace' where id;
select is((select shop_name from settings), 'Ace Racquets', 'but can''t change it');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update settings set shop_name = 'Ace Racquets & Strings' where id;
select is((select shop_name from settings), 'Ace Racquets & Strings', 'an admin can');

select * from finish();
rollback;
