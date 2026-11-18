-- Matrix Admin Centre: private administrator access and controlled moderation actions.
-- Run after the orders/payments, delivery/pickup and settings migrations.
-- IMPORTANT: This migration does NOT make any account an administrator.
-- Add a trusted adult/platform operator manually using the commented bootstrap SQL at the end.

create table if not exists public.matrix_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_label text not null default 'Matrix Administrator',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.matrix_admins enable row level security;
revoke all on public.matrix_admins from anon, authenticated;

create or replace function public.matrix_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.matrix_admins
    where user_id = auth.uid() and is_active = true
  );
$$;
revoke all on function public.matrix_is_admin() from public, anon;
grant execute on function public.matrix_is_admin() to authenticated;

-- Admin-only read access. Existing buyer/seller policies remain in force.
drop policy if exists "Matrix admins can view all orders" on public.matrix_orders;
create policy "Matrix admins can view all orders" on public.matrix_orders
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can view all order items" on public.matrix_order_items;
create policy "Matrix admins can view all order items" on public.matrix_order_items
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can view all disputes" on public.matrix_order_disputes;
create policy "Matrix admins can view all disputes" on public.matrix_order_disputes
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can view all seller payouts" on public.matrix_seller_payouts;
create policy "Matrix admins can view all seller payouts" on public.matrix_seller_payouts
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can view all seller pickup requests" on public.seller_pickup_locations;
create policy "Matrix admins can view all seller pickup requests" on public.seller_pickup_locations
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can view all Matrix pickup points" on public.matrix_pickup_points;
create policy "Matrix admins can view all Matrix pickup points" on public.matrix_pickup_points
for select to authenticated using (public.matrix_is_admin());

drop policy if exists "Matrix admins can manage account deletion requests" on public.account_deletion_requests;
create policy "Matrix admins can manage account deletion requests" on public.account_deletion_requests
for select to authenticated using (public.matrix_is_admin());

-- Admin-only RPCs. These functions verify the admin allowlist on every call.
create or replace function public.matrix_admin_review_pickup(
  p_location_id uuid, p_decision text, p_note text default null
)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Choose approved or rejected.'; end if;
  update public.seller_pickup_locations
  set status=p_decision, review_note=nullif(left(trim(coalesce(p_note,'')),500),''), reviewed_at=now(), updated_at=now()
  where id=p_location_id;
  if not found then raise exception 'Pickup request not found.'; end if;
end; $$;
revoke all on function public.matrix_admin_review_pickup(uuid,text,text) from public, anon;
grant execute on function public.matrix_admin_review_pickup(uuid,text,text) to authenticated;

create or replace function public.matrix_admin_update_order_status(
  p_order_id uuid, p_status text
)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_order public.matrix_orders%rowtype;
begin
  if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
  select * into v_order from public.matrix_orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status <> 'paid' then raise exception 'Only paid orders can move through fulfilment.'; end if;
  if not (
    (v_order.status='paid' and p_status='processing') or
    (v_order.status='processing' and p_status in ('ready_for_pickup','shipped')) or
    (v_order.status='ready_for_pickup' and p_status='delivered') or
    (v_order.status='shipped' and p_status='delivered')
  ) then raise exception 'That order status transition is not allowed.'; end if;
  if v_order.fulfillment_method='matrix_delivery' and p_status='ready_for_pickup' then raise exception 'Delivery orders cannot be marked ready for pickup.'; end if;
  if v_order.fulfillment_method<>'matrix_delivery' and p_status='shipped' then raise exception 'Pickup orders cannot be marked shipped.'; end if;
  update public.matrix_orders set status=p_status,updated_at=now() where id=p_order_id;
end; $$;
revoke all on function public.matrix_admin_update_order_status(uuid,text) from public, anon;
grant execute on function public.matrix_admin_update_order_status(uuid,text) to authenticated;

create or replace function public.matrix_admin_resolve_dispute(
  p_dispute_id uuid, p_resolution text, p_note text
)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v public.matrix_order_disputes%rowtype;
begin
  if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
  if p_resolution not in ('resolved_buyer','resolved_seller','closed') then raise exception 'Choose a valid resolution.'; end if;
  if length(trim(coalesce(p_note,''))) < 10 then raise exception 'Add a resolution note of at least 10 characters.'; end if;
  select * into v from public.matrix_order_disputes where id=p_dispute_id for update;
  if not found then raise exception 'Dispute not found.'; end if;
  if v.status not in ('open','under_review') then raise exception 'This dispute has already been handled.'; end if;
  update public.matrix_order_disputes set status=p_resolution,resolution_note=left(trim(p_note),1500),updated_at=now() where id=p_dispute_id;
  -- No refund or payout is triggered here. Those require verified payment-provider operations.
end; $$;
revoke all on function public.matrix_admin_resolve_dispute(uuid,text,text) from public, anon;
grant execute on function public.matrix_admin_resolve_dispute(uuid,text,text) to authenticated;

create or replace function public.matrix_admin_set_dispute_review(p_dispute_id uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
  update public.matrix_order_disputes set status='under_review',updated_at=now()
  where id=p_dispute_id and status='open';
  if not found then raise exception 'Open dispute not found.'; end if;
end; $$;
revoke all on function public.matrix_admin_set_dispute_review(uuid) from public, anon;
grant execute on function public.matrix_admin_set_dispute_review(uuid) to authenticated;

create or replace function public.matrix_admin_review_deletion(
  p_request_id uuid, p_decision text
)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
  if p_decision not in ('reviewing','rejected') then raise exception 'Choose reviewing or rejected.'; end if;
  update public.account_deletion_requests set status=p_decision
  where id=p_request_id and status='pending';
  if not found then raise exception 'Pending account request not found.'; end if;
end; $$;
revoke all on function public.matrix_admin_review_deletion(uuid,text) from public, anon;
grant execute on function public.matrix_admin_review_deletion(uuid,text) to authenticated;

-- To grant access to a trusted administrator, first find their auth.users UUID
-- in Supabase Dashboard > Authentication > Users, then run this separately:
-- insert into public.matrix_admins(user_id, display_label)
-- values ('PASTE-TRUSTED-USER-UUID-HERE', 'Matrix Admin')
-- on conflict (user_id) do update set is_active=true, display_label=excluded.display_label;
--
-- To revoke admin access:
-- update public.matrix_admins set is_active=false where user_id='USER-UUID';
