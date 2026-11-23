-- =============================================================================
-- 0072_demo_conversions.sql — demos that led to a sale (AceStock, Phase 3C)
--
-- Before:
--   • A demo loan (0071) said who borrowed which frame, but not whether the
--     customer went on to buy that racquet.
--
-- Now:
--   1. demo_loans.sale_id: the sale the demo led to.
--   2. link_demo_sale trigger: when a frame is sold to a customer, their
--      latest loan of a frame of the same racquet (product), taken out in the
--      30 days before and not yet linked, is linked to the sale. It doesn't
--      matter whether they buy the demo frame itself (moved back in stock
--      first) or a new one, or whether the demo is still out.
--
-- A walk-in sale (no customer) links nothing. A later return of the frame
-- leaves the link: the demo still led to that sale. Re-runnable.
-- =============================================================================

alter table demo_loans add column if not exists sale_id uuid references sales (id);
comment on column demo_loans.sale_id is 'The sale this demo led to: the customer bought a frame of the same racquet';
create index if not exists ix_demo_loans_sale on demo_loans (sale_id) where sale_id is not null;

-- -----------------------------------------------------------------------------
-- link_demo_sale — a frame sold to a customer who demoed that racquet
-- -----------------------------------------------------------------------------
create or replace function link_demo_sale()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status <> 'sold' or old.status = 'sold' or new.customer_id is null or new.sale_id is null then
    return new;
  end if;

  update demo_loans
     set sale_id = new.sale_id
   where id = (
     select l.id
       from demo_loans l
       join product_units u on u.id = l.product_unit_id
      where l.customer_id = new.customer_id
        and u.product_id = new.product_id
        and l.sale_id is null
        and l.out_at >= now() - interval '30 days'
      order by l.out_at desc, l.loan_number desc
      limit 1
      for update of l
   );
  return new;
end;
$$;

revoke all on function link_demo_sale() from public, anon, authenticated;

drop trigger if exists trg_link_demo_sale on product_units;
create trigger trg_link_demo_sale
  after update of status on product_units
  for each row execute function link_demo_sale();
