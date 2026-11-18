-- Matrix Marketplace: seller product listings
-- Run this once in Supabase Dashboard > SQL Editor > New query.

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 2 and 90),
  description text not null check (char_length(description) between 5 and 1200),
  price numeric(12,2) not null check (price > 0),
  category text not null,
  condition text not null check (condition in ('New','Used')),
  image_url text,
  status text not null default 'active' check (status in ('active','sold','hidden')),
  created_at timestamptz not null default now()
);

alter table public.products enable row level security;

drop policy if exists "Anyone can view active products" on public.products;
create policy "Anyone can view active products"
on public.products for select
using (status = 'active' or auth.uid() = seller_id);

drop policy if exists "Sellers can create their own products" on public.products;
create policy "Sellers can create their own products"
on public.products for insert
to authenticated
with check (auth.uid() = seller_id);

drop policy if exists "Sellers can update their own products" on public.products;
create policy "Sellers can update their own products"
on public.products for update
to authenticated
using (auth.uid() = seller_id)
with check (auth.uid() = seller_id);

drop policy if exists "Sellers can delete their own products" on public.products;
create policy "Sellers can delete their own products"
on public.products for delete
to authenticated
using (auth.uid() = seller_id);

grant select, insert, update, delete on public.products to anon, authenticated;


-- Product photo storage (safe to run after the products setup)
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update set public = true;

drop policy if exists "Public can view product photos" on storage.objects;
create policy "Public can view product photos"
on storage.objects for select
using (bucket_id = 'product-images');

drop policy if exists "Sellers can upload their own product photos" on storage.objects;
create policy "Sellers can upload their own product photos"
on storage.objects for insert to authenticated
with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Sellers can update their own product photos" on storage.objects;
create policy "Sellers can update their own product photos"
on storage.objects for update to authenticated
using (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text)
with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Sellers can delete their own product photos" on storage.objects;
create policy "Sellers can delete their own product photos"
on storage.objects for delete to authenticated
using (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);
