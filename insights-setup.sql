-- Matrix Marketplace Seller Insights
-- Run this in Supabase SQL Editor after seller-setup.sql.

create table if not exists public.product_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  event_type text not null check (event_type in ('view','cart_add','favorite')),
  visitor_key text,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists product_events_product_type_idx
  on public.product_events(product_id, event_type);
create index if not exists product_events_created_at_idx
  on public.product_events(created_at);

alter table public.product_events enable row level security;

drop policy if exists "Visitors can record activity on active products" on public.product_events;
create policy "Visitors can record activity on active products"
on public.product_events for insert
to anon, authenticated
with check (
  exists (
    select 1 from public.products p
    where p.id = product_id and p.status = 'active'
  )
  and (user_id is null or user_id = auth.uid())
);

-- No direct SELECT policy is provided: sellers must not be able to inspect
-- individual visitors' identities or browsing history.

create or replace function public.get_my_product_insights()
returns table (
  product_id uuid,
  views bigint,
  cart_adds bigint,
  favorites bigint
)
language sql
security definer
set search_path = public
as $$
  select p.id,
    count(e.id) filter (where e.event_type = 'view') as views,
    count(e.id) filter (where e.event_type = 'cart_add') as cart_adds,
    count(e.id) filter (where e.event_type = 'favorite') as favorites
  from public.products p
  left join public.product_events e on e.product_id = p.id
  where p.seller_id = auth.uid()
  group by p.id;
$$;

revoke all on function public.get_my_product_insights() from public;
grant execute on function public.get_my_product_insights() to authenticated;
grant insert on public.product_events to anon, authenticated;
