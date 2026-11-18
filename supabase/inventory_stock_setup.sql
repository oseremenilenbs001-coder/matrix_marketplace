-- Matrix Marketplace inventory / stock quantity migration
-- Run once in the Supabase SQL Editor before testing inventory.
alter table public.products
  add column if not exists stock_quantity integer not null default 1;

alter table public.products
  drop constraint if exists products_stock_quantity_nonnegative;

alter table public.products
  add constraint products_stock_quantity_nonnegative
  check (stock_quantity >= 0);

-- Allow each authenticated seller to update only their own listing rows.
alter table public.products enable row level security;
drop policy if exists "Sellers can update their own products" on public.products;
create policy "Sellers can update their own products"
  on public.products for update
  to authenticated
  using (auth.uid() = seller_id)
  with check (auth.uid() = seller_id);

grant update on public.products to authenticated;
