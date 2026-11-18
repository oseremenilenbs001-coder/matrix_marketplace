-- Matrix Marketplace: seller-controlled Hot Deal labels and crossed-out prices.
-- Run once in the Supabase SQL Editor.

alter table public.products
  add column if not exists original_price numeric(12,2),
  add column if not exists is_almost_out boolean not null default false;

alter table public.products
  drop constraint if exists products_original_price_gt_price;

alter table public.products
  add constraint products_original_price_gt_price
  check (original_price is null or original_price > price);

comment on column public.products.original_price is
  'Optional previous/list price. When greater than price, the marketplace displays a price slash and includes the product in Hot Deals.';
comment on column public.products.is_almost_out is
  'Seller-selected indicator that the product is almost out of stock. When true, the product is included in Hot Deals.';
