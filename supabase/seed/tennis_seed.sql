-- =============================================================================
-- tennis_seed.sql — AceStock sample catalog (PRODUCTS ONLY, no variants).
-- Real brands/models/prices; add items (variants) yourself with your fields.
-- Idempotent: first removes any prior run of these products AND any stock/
-- sales history on their variants, then re-inserts the products. Requires 0008+.
-- =============================================================================

-- Brands (pick-or-add lookup)
insert into lookup_values (kind, value) values
  ('brand','Wilson'),
  ('brand','Babolat'),
  ('brand','Head'),
  ('brand','Tecnifibre'),
  ('brand','Volkl'),
  ('brand','Yonex'),
  ('brand','Solinco'),
  ('brand','New Balance'),
  ('brand','On'),
  ('brand','K-Swiss')
on conflict (kind, value) do nothing;

-- Clean up prior run: clear ledger + sale lines on these products variants,
-- then delete the products (which cascades their variants).
delete from inventory_txns where variant_id in (
    select v.id from variants v join products p on p.id = v.product_id
    where (p.brand, p.name) in (
  ('Wilson','Pro Staff 97 v14'),
  ('Wilson','Blade 98 v9 (16x19)'),
  ('Babolat','Pure Aero (2023)'),
  ('Babolat','Pure Drive (2021)'),
  ('Head','Speed MP (2024)'),
  ('Head','Radical MP (2023)'),
  ('Tecnifibre','TFight 305 ISO'),
  ('Tecnifibre','TF-X1 300'),
  ('Volkl','V8 (V-Cell)'),
  ('Yonex','EZONE 100 (2022)'),
  ('Yonex','VCORE 98 (2023)'),
  ('Head','Lynx'),
  ('Head','Hawk Touch'),
  ('Tecnifibre','X-One Biphase'),
  ('Tecnifibre','Razor Code'),
  ('Wilson','NXT'),
  ('Wilson','Revolve'),
  ('Solinco','Hyperion'),
  ('Solinco','Tour Bite'),
  ('Babolat','RPM Blast'),
  ('Babolat','Xcel'),
  ('Volkl','Cyclone'),
  ('Yonex','Poly Tour Pro'),
  ('Babolat','Jet Mach 3 (Men)'),
  ('Babolat','Propulse Fury 3 (Men)'),
  ('New Balance','Fresh Foam X Lav v2 (Men)'),
  ('New Balance','996v5 (Men)'),
  ('On','The Roger Pro 2 (Men)'),
  ('On','The Roger Clubhouse (Men)'),
  ('Wilson','Rush Pro 4.0 (Men)'),
  ('Wilson','Kaos Swift 1.5 (Men)'),
  ('K-Swiss','Hypercourt Express 2 (Men)'),
  ('K-Swiss','Ultrashot 3 (Men)')
    )
  );

delete from sale_lines where variant_id in (
    select v.id from variants v join products p on p.id = v.product_id
    where (p.brand, p.name) in (
  ('Wilson','Pro Staff 97 v14'),
  ('Wilson','Blade 98 v9 (16x19)'),
  ('Babolat','Pure Aero (2023)'),
  ('Babolat','Pure Drive (2021)'),
  ('Head','Speed MP (2024)'),
  ('Head','Radical MP (2023)'),
  ('Tecnifibre','TFight 305 ISO'),
  ('Tecnifibre','TF-X1 300'),
  ('Volkl','V8 (V-Cell)'),
  ('Yonex','EZONE 100 (2022)'),
  ('Yonex','VCORE 98 (2023)'),
  ('Head','Lynx'),
  ('Head','Hawk Touch'),
  ('Tecnifibre','X-One Biphase'),
  ('Tecnifibre','Razor Code'),
  ('Wilson','NXT'),
  ('Wilson','Revolve'),
  ('Solinco','Hyperion'),
  ('Solinco','Tour Bite'),
  ('Babolat','RPM Blast'),
  ('Babolat','Xcel'),
  ('Volkl','Cyclone'),
  ('Yonex','Poly Tour Pro'),
  ('Babolat','Jet Mach 3 (Men)'),
  ('Babolat','Propulse Fury 3 (Men)'),
  ('New Balance','Fresh Foam X Lav v2 (Men)'),
  ('New Balance','996v5 (Men)'),
  ('On','The Roger Pro 2 (Men)'),
  ('On','The Roger Clubhouse (Men)'),
  ('Wilson','Rush Pro 4.0 (Men)'),
  ('Wilson','Kaos Swift 1.5 (Men)'),
  ('K-Swiss','Hypercourt Express 2 (Men)'),
  ('K-Swiss','Ultrashot 3 (Men)')
    )
  );

delete from products where (brand, name) in (
  ('Wilson','Pro Staff 97 v14'),
  ('Wilson','Blade 98 v9 (16x19)'),
  ('Babolat','Pure Aero (2023)'),
  ('Babolat','Pure Drive (2021)'),
  ('Head','Speed MP (2024)'),
  ('Head','Radical MP (2023)'),
  ('Tecnifibre','TFight 305 ISO'),
  ('Tecnifibre','TF-X1 300'),
  ('Volkl','V8 (V-Cell)'),
  ('Yonex','EZONE 100 (2022)'),
  ('Yonex','VCORE 98 (2023)'),
  ('Head','Lynx'),
  ('Head','Hawk Touch'),
  ('Tecnifibre','X-One Biphase'),
  ('Tecnifibre','Razor Code'),
  ('Wilson','NXT'),
  ('Wilson','Revolve'),
  ('Solinco','Hyperion'),
  ('Solinco','Tour Bite'),
  ('Babolat','RPM Blast'),
  ('Babolat','Xcel'),
  ('Volkl','Cyclone'),
  ('Yonex','Poly Tour Pro'),
  ('Babolat','Jet Mach 3 (Men)'),
  ('Babolat','Propulse Fury 3 (Men)'),
  ('New Balance','Fresh Foam X Lav v2 (Men)'),
  ('New Balance','996v5 (Men)'),
  ('On','The Roger Pro 2 (Men)'),
  ('On','The Roger Clubhouse (Men)'),
  ('Wilson','Rush Pro 4.0 (Men)'),
  ('Wilson','Kaos Swift 1.5 (Men)'),
  ('K-Swiss','Hypercourt Express 2 (Men)'),
  ('K-Swiss','Ultrashot 3 (Men)')
);

-- Products (no variants — add items with your own fields).
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'aed60433-35a3-471d-887c-99229d76a628', c.id, 'Wilson', 'Pro Staff 97 v14', 259, 145, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '99c3cd5c-0370-4a1d-af8d-05298c390f1d', c.id, 'Wilson', 'Blade 98 v9 (16x19)', 259, 145, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '390d0f43-1fcf-47b3-9a5f-c64301924386', c.id, 'Babolat', 'Pure Aero (2023)', 279, 155, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'd49a83e8-bb69-4760-bb37-5ecf17aa1c7f', c.id, 'Babolat', 'Pure Drive (2021)', 249, 140, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '986344ed-55d6-4236-b2af-7cfbcefdce0b', c.id, 'Head', 'Speed MP (2024)', 269, 150, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '72816348-8b5b-4568-b7d7-8c7d913bef41', c.id, 'Head', 'Radical MP (2023)', 249, 140, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'd5d0aedd-dd45-4696-8745-1482e0145921', c.id, 'Tecnifibre', 'TFight 305 ISO', 259, 145, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '7fcef639-3fdc-493a-801a-ace3688fa63e', c.id, 'Tecnifibre', 'TF-X1 300', 219, 120, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'bbda0997-2a0d-4b02-9f97-00050a41165d', c.id, 'Volkl', 'V8 (V-Cell)', 219, 120, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '0dc0dac5-4cdf-4248-a76b-983ce979f411', c.id, 'Yonex', 'EZONE 100 (2022)', 259, 145, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '4ca22dfa-52ac-4cc0-97cb-2c26a3579d24', c.id, 'Yonex', 'VCORE 98 (2023)', 259, 145, 2
from categories c where c.name = 'Rackets';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '5930b962-578d-4978-a4ab-dbef3922d2be', c.id, 'Head', 'Lynx', 16, 7, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'c9773329-b93d-43dc-b52c-15caf96f3c02', c.id, 'Head', 'Hawk Touch', 17, 7.5, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'a9a50057-fe1f-42f8-bc1e-2041e6e52b00', c.id, 'Tecnifibre', 'X-One Biphase', 22, 10, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '047d7274-584d-48dd-8a40-5d91eece20c3', c.id, 'Tecnifibre', 'Razor Code', 18, 8, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'e67752c3-1664-4b93-b458-c47de068f90c', c.id, 'Wilson', 'NXT', 20, 9, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'f54f798b-6088-4553-a6ea-c32e6edf5fd3', c.id, 'Wilson', 'Revolve', 15, 6.5, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '10ac4f97-b452-40e4-ae1a-db942bf4ae34', c.id, 'Solinco', 'Hyperion', 18, 8, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '6a02d63e-5d3b-45a2-a9cf-7721805436e7', c.id, 'Solinco', 'Tour Bite', 17, 7.5, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '6ce8131e-21b6-4450-bfbd-e745b00c93f1', c.id, 'Babolat', 'RPM Blast', 19, 8.5, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '9eb0cffc-36b5-4b8d-9d23-0bd767de2dd0', c.id, 'Babolat', 'Xcel', 21, 9.5, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '7deb7614-e219-4e2a-bcc7-c27358bf0f65', c.id, 'Volkl', 'Cyclone', 14, 6, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'b70003fe-e9f4-488d-9fa3-2917c3727f6c', c.id, 'Yonex', 'Poly Tour Pro', 18, 8, 4
from categories c where c.name = 'Strings';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '43fefa8d-6077-4416-be67-9c79e1460a84', c.id, 'Babolat', 'Jet Mach 3 (Men)', 150, 80, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '5dd349c7-efbf-4278-ab01-628e9fc26ba6', c.id, 'Babolat', 'Propulse Fury 3 (Men)', 140, 75, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'd7ee0587-7cfe-4cd9-b3e6-a96c1bb9d90e', c.id, 'New Balance', 'Fresh Foam X Lav v2 (Men)', 145, 78, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '20a8fd95-7661-4f93-a69d-2cc54566dc0c', c.id, 'New Balance', '996v5 (Men)', 130, 70, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '7f48636c-a68a-4dfd-b7a0-3c17147c111a', c.id, 'On', 'The Roger Pro 2 (Men)', 250, 135, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '67c82e82-510e-417c-adb4-effad9230add', c.id, 'On', 'The Roger Clubhouse (Men)', 150, 80, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select 'f24b2d1b-a10e-4df0-aad4-fd3d6681395d', c.id, 'Wilson', 'Rush Pro 4.0 (Men)', 140, 75, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '010734cf-d781-4747-8830-4dfc248acfb8', c.id, 'Wilson', 'Kaos Swift 1.5 (Men)', 110, 58, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '8d1b620d-de30-4c2f-ad79-12f7fbbf7a16', c.id, 'K-Swiss', 'Hypercourt Express 2 (Men)', 110, 58, 2
from categories c where c.name = 'Shoes';
insert into products (id, category_id, brand, name, sell_price, cost, reorder_point)
select '80d3f7f9-b452-4e3c-8066-fe34d3dd5850', c.id, 'K-Swiss', 'Ultrashot 3 (Men)', 130, 70, 2
from categories c where c.name = 'Shoes';

