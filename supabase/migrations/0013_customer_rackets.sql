-- =============================================================================
-- 0013_customer_rackets.sql — rackets a customer owns (AceStock)
--
-- The physical rackets a customer owns. Each may optionally link to a catalog
-- racket (products) if it's a model the shop sells, or be free-form for a racket
-- bought elsewhere. This is the anchor for re-stringing history (a future
-- feature: each stringing event references a customer_racket).
-- =============================================================================

create table customer_rackets (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers (id) on delete cascade,
  product_id   uuid references products (id),   -- optional link to a catalog racket
  brand        text,
  model        text not null,                   -- racket name/model (identifies it)
  grip_size    text,
  label        text,                            -- nickname to tell multiple rackets apart
  notes        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index idx_customer_rackets_customer on customer_rackets (customer_id);
create index idx_customer_rackets_product on customer_rackets (product_id);

create trigger trg_customer_rackets_updated_at
  before update on customer_rackets
  for each row execute function set_updated_at();

-- RLS + grants
alter table customer_rackets enable row level security;
create policy customer_rackets_authenticated_all
  on customer_rackets for all to authenticated using (true) with check (true);
grant select, insert, update, delete on customer_rackets to authenticated;
