-- Matrix Marketplace: secure order, payment-state, inventory and dispute foundation.
-- Run once in Supabase SQL Editor. This does NOT connect a live payment gateway.
-- Live payment verification must be performed by a trusted server/webhook, never the browser.
 
create table if not exists public.matrix_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('MX-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  buyer_id uuid not null references auth.users(id) on delete restrict,
  seller_id uuid not null references auth.users(id) on delete restrict,
  fulfillment_method text not null check (fulfillment_method in ('matrix_delivery','matrix_pickup','seller_pickup')),
  delivery_address text,
  delivery_area text,
  matrix_pickup_point_id uuid references public.matrix_pickup_points(id) on delete restrict,
  seller_pickup_location_id uuid references public.seller_pickup_locations(id) on delete restrict,
  subtotal numeric(12,2) not null check (subtotal >= 0),
  delivery_fee numeric(12,2) not null default 0 check (delivery_fee >= 0),
  total_amount numeric(12,2) not null check (total_amount = subtotal + delivery_fee),
  status text not null default 'awaiting_payment'
    check (status in ('awaiting_payment','paid','processing','ready_for_pickup','shipped','delivered','completed','cancelled','disputed')),
  payment_status text not null default 'pending'
    check (payment_status in ('pending','paid','failed','refunded','partially_refunded')),
  buyer_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint matrix_orders_fulfillment_details check (
    (fulfillment_method = 'matrix_delivery' and delivery_address is not null and length(trim(delivery_address)) > 0 and delivery_area is not null and length(trim(delivery_area)) > 0 and matrix_pickup_point_id is null and seller_pickup_location_id is null)
    or (fulfillment_method = 'matrix_pickup' and matrix_pickup_point_id is not null and delivery_address is null and seller_pickup_location_id is null)
    or (fulfillment_method = 'seller_pickup' and seller_pickup_location_id is not null and delivery_address is null and matrix_pickup_point_id is null)
  )
);

create table if not exists public.matrix_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.matrix_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_title text not null,
  product_image_url text,
  seller_id uuid not null references auth.users(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) not null check (line_total = quantity * unit_price),
  created_at timestamptz not null default now()
);

create table if not exists public.matrix_payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.matrix_orders(id) on delete restrict,
  buyer_id uuid not null references auth.users(id) on delete restrict,
  provider text not null default 'not_configured',
  provider_reference text unique,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  status text not null default 'pending' check (status in ('pending','successful','failed','refunded','partially_refunded')),
  checkout_url text,
  provider_metadata jsonb not null default '{}'::jsonb,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.matrix_order_disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.matrix_orders(id) on delete restrict,
  buyer_id uuid not null references auth.users(id) on delete restrict,
  seller_id uuid not null references auth.users(id) on delete restrict,
  category text not null check (category in ('not_received','wrong_item','damaged_item','missing_item','other')),
  description text not null check (length(trim(description)) between 10 and 3000),
  status text not null default 'open' check (status in ('open','under_review','resolved_buyer','resolved_seller','closed')),
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.matrix_seller_payouts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.matrix_orders(id) on delete restrict,
  seller_id uuid not null references auth.users(id) on delete restrict,
  gross_amount numeric(12,2) not null check (gross_amount >= 0),
  matrix_commission numeric(12,2) not null default 0 check (matrix_commission >= 0),
  net_amount numeric(12,2) not null check (net_amount = gross_amount - matrix_commission and net_amount >= 0),
  status text not null default 'awaiting_delivery_confirmation'
    check (status in ('awaiting_delivery_confirmation','eligible_for_provider_payout','payout_processing','paid','on_hold','cancelled')),
  provider_transfer_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id,seller_id)
);

create index if not exists matrix_orders_buyer_created_idx on public.matrix_orders(buyer_id,created_at desc);
create index if not exists matrix_orders_seller_created_idx on public.matrix_orders(seller_id,created_at desc);
create index if not exists matrix_order_items_order_idx on public.matrix_order_items(order_id);
create index if not exists matrix_disputes_order_idx on public.matrix_order_disputes(order_id,created_at desc);
create index if not exists matrix_payments_buyer_idx on public.matrix_payments(buyer_id,created_at desc);

alter table public.matrix_orders enable row level security;
alter table public.matrix_order_items enable row level security;
alter table public.matrix_payments enable row level security;
alter table public.matrix_order_disputes enable row level security;
alter table public.matrix_seller_payouts enable row level security;

drop policy if exists "Order participants can view orders" on public.matrix_orders;
create policy "Order participants can view orders" on public.matrix_orders for select to authenticated
using (buyer_id = auth.uid() or seller_id = auth.uid());

drop policy if exists "Order participants can view items" on public.matrix_order_items;
create policy "Order participants can view items" on public.matrix_order_items for select to authenticated
using (exists (select 1 from public.matrix_orders o where o.id = order_id and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())));

drop policy if exists "Buyers can view their payment records" on public.matrix_payments;
create policy "Buyers can view their payment records" on public.matrix_payments for select to authenticated
using (buyer_id = auth.uid());

drop policy if exists "Order participants can view disputes" on public.matrix_order_disputes;
create policy "Order participants can view disputes" on public.matrix_order_disputes for select to authenticated
using (buyer_id = auth.uid() or seller_id = auth.uid());

drop policy if exists "Sellers can view their payout records" on public.matrix_seller_payouts;
create policy "Sellers can view their payout records" on public.matrix_seller_payouts for select to authenticated
using (seller_id = auth.uid());

-- No browser role can create/alter payment or payout states.
revoke all on public.matrix_payments, public.matrix_seller_payouts from anon, authenticated;
grant select on public.matrix_payments, public.matrix_seller_payouts to authenticated;
revoke all on public.matrix_orders, public.matrix_order_items, public.matrix_order_disputes from anon, authenticated;
grant select on public.matrix_orders, public.matrix_order_items, public.matrix_order_disputes to authenticated;

-- Atomically validates stock, reserves it, and creates one order for one seller.
-- Cart items format: [{"product_id":"uuid","quantity":2}, ...]
create or replace function public.matrix_create_order(
  p_items jsonb,
  p_fulfillment_method text,
  p_delivery_address text default null,
  p_delivery_area text default null,
  p_delivery_fee numeric default 0,
  p_matrix_pickup_point_id uuid default null,
  p_seller_pickup_location_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer uuid := auth.uid();
  v_seller uuid;
  v_order_id uuid;
  v_subtotal numeric(12,2) := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_title text;
  v_image text;
  v_price numeric(12,2);
  v_count integer := 0;
begin
  if v_buyer is null then raise exception 'Please sign in before checkout.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Your cart is empty.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'An order can contain at most 30 different products.'; end if;
  if p_delivery_fee is null or p_delivery_fee < 0 then raise exception 'Invalid delivery fee.'; end if;
  if p_fulfillment_method not in ('matrix_delivery','matrix_pickup','seller_pickup') then raise exception 'Choose a valid delivery or pickup method.'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'product_id','') = '' or coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then
      raise exception 'Invalid product or quantity in cart.';
    end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 100 then raise exception 'Each product quantity must be between 1 and 100.'; end if;
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid for update;
    if not found or v_product.status <> 'active' then raise exception 'A product in your cart is no longer available.'; end if;
    if v_product.seller_id = v_buyer then raise exception 'You cannot purchase your own listing.'; end if;
    if v_product.stock_quantity < v_qty then raise exception 'Not enough stock for % (available: %).',v_product.title,v_product.stock_quantity; end if;
    if v_seller is null then v_seller := v_product.seller_id;
    elsif v_seller <> v_product.seller_id then raise exception 'For now, place separate orders for products from different sellers.'; end if;
    v_count := v_count + 1;
    if v_count > 30 then raise exception 'Too many different products in this order.'; end if;
    v_subtotal := v_subtotal + (v_product.price * v_qty);
  end loop;

  if p_fulfillment_method = 'matrix_delivery' then
    if nullif(trim(p_delivery_address),'') is null or nullif(trim(p_delivery_area),'') is null then raise exception 'Enter your delivery address and confirm the delivery area.'; end if;
    if p_matrix_pickup_point_id is not null or p_seller_pickup_location_id is not null then raise exception 'Invalid delivery selection.'; end if;
  elsif p_fulfillment_method = 'matrix_pickup' then
    if p_matrix_pickup_point_id is null or not exists(select 1 from public.matrix_pickup_points where id=p_matrix_pickup_point_id and status='active') then raise exception 'That Matrix pickup point is not available.'; end if;
    if p_delivery_address is not null or p_seller_pickup_location_id is not null then raise exception 'Invalid pickup selection.'; end if;
  else
    if p_seller_pickup_location_id is null or not exists(select 1 from public.seller_pickup_locations where id=p_seller_pickup_location_id and seller_id=v_seller and status='approved') then raise exception 'That seller pickup location is not approved or does not belong to this seller.'; end if;
    if p_delivery_address is not null or p_matrix_pickup_point_id is not null then raise exception 'Invalid seller pickup selection.'; end if;
  end if;

  insert into public.matrix_orders(buyer_id,seller_id,fulfillment_method,delivery_address,delivery_area,matrix_pickup_point_id,seller_pickup_location_id,subtotal,delivery_fee,total_amount)
  values(v_buyer,v_seller,p_fulfillment_method,nullif(trim(p_delivery_address),''),nullif(trim(p_delivery_area),''),p_matrix_pickup_point_id,p_seller_pickup_location_id,v_subtotal,p_delivery_fee,v_subtotal+p_delivery_fee)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
    update public.products set stock_quantity=stock_quantity-v_qty where id=v_product.id;
    insert into public.matrix_order_items(order_id,product_id,product_title,product_image_url,seller_id,quantity,unit_price,line_total)
    values(v_order_id,v_product.id,v_product.title,v_product.image_url,v_product.seller_id,v_qty,v_product.price,v_product.price*v_qty);
  end loop;

  insert into public.matrix_payments(order_id,buyer_id,amount) values(v_order_id,v_buyer,v_subtotal+p_delivery_fee);
  insert into public.matrix_seller_payouts(order_id,seller_id,gross_amount,matrix_commission,net_amount)
  values(v_order_id,v_seller,v_subtotal,0,v_subtotal);

  return v_order_id;
end;
$$;

revoke all on function public.matrix_create_order(jsonb,text,text,text,numeric,uuid,uuid) from public, anon;
grant execute on function public.matrix_create_order(jsonb,text,text,text,numeric,uuid,uuid) to authenticated;

-- Buyer can cancel only an unpaid order; stock is restored under row locks.
create or replace function public.matrix_cancel_unpaid_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_order public.matrix_orders%rowtype; v_item public.matrix_order_items%rowtype;
begin
  select * into v_order from public.matrix_orders where id=p_order_id and buyer_id=auth.uid() for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.status <> 'awaiting_payment' or v_order.payment_status <> 'pending' then raise exception 'Only unpaid orders can be cancelled here.'; end if;
  for v_item in select * from public.matrix_order_items where order_id=p_order_id loop
    if v_item.product_id is not null then
      update public.products set stock_quantity=stock_quantity+v_item.quantity where id=v_item.product_id;
    end if;
  end loop;
  update public.matrix_orders set status='cancelled',updated_at=now() where id=p_order_id;
  update public.matrix_seller_payouts set status='cancelled',updated_at=now() where order_id=p_order_id;
end;
$$;
revoke all on function public.matrix_cancel_unpaid_order(uuid) from public, anon;
grant execute on function public.matrix_cancel_unpaid_order(uuid) to authenticated;

-- Buyer can open a dispute for an order they paid for.
create or replace function public.matrix_open_dispute(p_order_id uuid,p_category text,p_description text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_order public.matrix_orders%rowtype; v_dispute uuid;
begin
  select * into v_order from public.matrix_orders where id=p_order_id and buyer_id=auth.uid() for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status <> 'paid' then raise exception 'A dispute can only be opened for a paid order.'; end if;
  if v_order.status in ('cancelled','completed') then raise exception 'This order can no longer be disputed.'; end if;
  if exists(select 1 from public.matrix_order_disputes where order_id=p_order_id and status in ('open','under_review')) then raise exception 'This order already has an open dispute.'; end if;
  insert into public.matrix_order_disputes(order_id,buyer_id,seller_id,category,description)
  values(p_order_id,auth.uid(),v_order.seller_id,p_category,trim(p_description)) returning id into v_dispute;
  update public.matrix_orders set status='disputed',updated_at=now() where id=p_order_id;
  update public.matrix_seller_payouts set status='on_hold',updated_at=now() where order_id=p_order_id;
  return v_dispute;
end;
$$;
revoke all on function public.matrix_open_dispute(uuid,text,text) from public, anon;
grant execute on function public.matrix_open_dispute(uuid,text,text) to authenticated;

-- Buyer confirmation makes the seller payout ELIGIBLE; it does not send money.
create or replace function public.matrix_confirm_order_received(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_order public.matrix_orders%rowtype;
begin
  select * into v_order from public.matrix_orders where id=p_order_id and buyer_id=auth.uid() for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status <> 'paid' or v_order.status <> 'delivered' then raise exception 'This order must be paid and marked delivered before confirmation.'; end if;
  if exists(select 1 from public.matrix_order_disputes where order_id=p_order_id and status in ('open','under_review')) then raise exception 'Resolve the open dispute before confirming receipt.'; end if;
  update public.matrix_orders set status='completed',buyer_confirmed_at=now(),updated_at=now() where id=p_order_id;
  update public.matrix_seller_payouts set status='eligible_for_provider_payout',updated_at=now() where order_id=p_order_id and status='awaiting_delivery_confirmation';
end;
$$;
revoke all on function public.matrix_confirm_order_received(uuid) from public, anon;
grant execute on function public.matrix_confirm_order_received(uuid) to authenticated;

-- Trusted server/payment webhook responsibilities (not exposed to browser):
-- 1) Verify provider signature and transaction status/amount/currency.
-- 2) Update matrix_payments.status='successful', provider_reference, verified_at.
-- 3) Update matrix_orders.payment_status='paid', status='paid'.
-- 4) Move payout from awaiting_delivery_confirmation only after buyer confirmation;
--    a payment provider must explicitly support the approved delayed settlement model.
-- 5) Never accept a browser-supplied "paid" flag.
-- Delivery status updates and dispute resolution also require trusted server/admin actions.
