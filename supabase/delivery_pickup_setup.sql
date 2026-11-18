-- Matrix Marketplace: delivery coverage and pickup locations
-- Run once in the Supabase SQL Editor.
-- The first official Matrix checkpoint is intentionally not pre-filled:
-- add its real address only after Matrix confirms the physical location.

create table if not exists public.matrix_pickup_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  directions text not null,
  contact_phone text,
  operating_hours text not null,
  status text not null default 'inactive'
    check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.matrix_pickup_points enable row level security;

drop policy if exists "Anyone can view active Matrix pickup points" on public.matrix_pickup_points;
create policy "Anyone can view active Matrix pickup points"
  on public.matrix_pickup_points for select
  to anon, authenticated
  using (status = 'active');

grant select on public.matrix_pickup_points to anon, authenticated;

create table if not exists public.seller_pickup_locations (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  location_name text not null,
  address text not null,
  directions text not null,
  contact_phone text not null,
  operating_hours text not null,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected')),
  review_note text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists seller_pickup_locations_seller_idx
  on public.seller_pickup_locations(seller_id, created_at desc);

alter table public.seller_pickup_locations enable row level security;

drop policy if exists "Sellers can view their requests and approved locations" on public.seller_pickup_locations;
create policy "Sellers can view their requests and approved locations"
  on public.seller_pickup_locations for select
  to authenticated
  using (seller_id = auth.uid() or status = 'approved');

drop policy if exists "Sellers can submit pickup requests" on public.seller_pickup_locations;
create policy "Sellers can submit pickup requests"
  on public.seller_pickup_locations for insert
  to authenticated
  with check (seller_id = auth.uid() and status = 'pending');

drop policy if exists "Sellers can edit their pending pickup requests" on public.seller_pickup_locations;
create policy "Sellers can edit their pending pickup requests"
  on public.seller_pickup_locations for update
  to authenticated
  using (seller_id = auth.uid() and status = 'pending')
  with check (seller_id = auth.uid() and status = 'pending');

grant select, insert, update on public.seller_pickup_locations to authenticated;

-- Only a trusted administrator should change a seller request to approved/rejected
-- or activate an official Matrix checkpoint. Do this in the Supabase dashboard,
-- never by exposing a service-role key in browser code.
