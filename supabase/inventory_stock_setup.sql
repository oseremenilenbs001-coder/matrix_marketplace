-- Matrix Marketplace inventory / stock quantity migration
-- Run once in the Supabase SQL Editor before testing inventory.
alter table public.products
  add column if not exists stock_quantity integer not null default 1;

alter table public.products
  drop constraint if exists products_stock_quantity_nonnegative;

alter table public.products
  add constraint products_stock_quantity_nonnegative
  check (stock_quantity >= 0);
