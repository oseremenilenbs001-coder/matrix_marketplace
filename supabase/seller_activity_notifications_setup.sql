-- Matrix Marketplace: expanded seller activity notifications.
-- Run this file once in Supabase SQL Editor after the existing seller notification setup.

alter table public.matrix_seller_notifications
  alter column order_id drop not null;

alter table public.matrix_seller_notifications
  add column if not exists notification_type text not null default 'new_order',
  add column if not exists related_id uuid;

alter table public.matrix_seller_notifications
  drop constraint if exists matrix_seller_notifications_notification_type_check;

alter table public.matrix_seller_notifications
  add constraint matrix_seller_notifications_notification_type_check
  check (notification_type in (
    'new_order','order_update','pickup_update',
    'dispute_update','payout_update'
  ));

-- A single helper keeps notification inserts consistent and database-controlled.
create or replace function public.matrix_add_seller_notification(
  p_seller_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_order_id uuid default null,
  p_related_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_seller_id is null then return; end if;
  insert into public.matrix_seller_notifications
    (seller_id, notification_type, title, message, order_id, related_id)
  values (p_seller_id, p_type, p_title, p_message, p_order_id, p_related_id);
end;
$$;

revoke all on function public.matrix_add_seller_notification(uuid,text,text,text,uuid,uuid)
  from public, anon, authenticated;

-- New orders and later order/payment status changes.
create or replace function public.matrix_notify_seller_order_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_summary text;
begin
  if tg_op = 'INSERT' then
    select string_agg(i.product_title || ' × ' || i.quantity::text, ', ' order by i.created_at)
      into v_summary
      from public.matrix_order_items i where i.order_id = new.id;

    perform public.matrix_add_seller_notification(
      new.seller_id, 'new_order', 'New order received',
      'Order ' || new.order_number || ' · ' || coalesce(v_summary, 'New items') ||
      ' · ₦' || to_char(new.total_amount, 'FM999,999,990.00'),
      new.id, new.id
    );
    return new;
  end if;

  if old.status is distinct from new.status then
    perform public.matrix_add_seller_notification(
      new.seller_id, 'order_update', 'Order status updated',
      'Order ' || new.order_number || ' is now ' || replace(new.status, '_', ' ') || '.',
      new.id, new.id
    );
  end if;

  if old.payment_status is distinct from new.payment_status then
    perform public.matrix_add_seller_notification(
      new.seller_id, 'order_update', 'Payment status updated',
      'Payment for order ' || new.order_number || ' is now ' ||
      replace(new.payment_status, '_', ' ') || '.',
      new.id, new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists matrix_order_seller_notification on public.matrix_orders;
drop trigger if exists matrix_seller_order_activity_insert on public.matrix_orders;
drop trigger if exists matrix_seller_order_activity_update on public.matrix_orders;

create trigger matrix_seller_order_activity_insert
after insert on public.matrix_orders
for each row execute function public.matrix_notify_seller_order_activity();

create trigger matrix_seller_order_activity_update
after update of status, payment_status on public.matrix_orders
for each row
when (old.status is distinct from new.status or old.payment_status is distinct from new.payment_status)
execute function public.matrix_notify_seller_order_activity();

-- Seller pickup request approvals/rejections.
create or replace function public.matrix_notify_seller_pickup_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.status is distinct from new.status then
    perform public.matrix_add_seller_notification(
      new.seller_id, 'pickup_update', 'Pickup location request updated',
      'Your pickup location "' || new.location_name || '" was ' ||
      replace(new.status, '_', ' ') ||
      case when coalesce(new.review_note, '') <> '' then '. Note: ' || new.review_note else '.' end,
      null, new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists matrix_seller_pickup_activity_update on public.seller_pickup_locations;
create trigger matrix_seller_pickup_activity_update
after update of status on public.seller_pickup_locations
for each row
when (old.status is distinct from new.status)
execute function public.matrix_notify_seller_pickup_activity();

-- Disputes opened by buyers and subsequent dispute status changes.
create or replace function public.matrix_notify_seller_dispute_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_number text;
begin
  select order_number into v_order_number
    from public.matrix_orders where id = new.order_id;

  if tg_op = 'INSERT' then
    perform public.matrix_add_seller_notification(
      new.seller_id, 'dispute_update', 'A buyer opened a dispute',
      'A dispute was opened for order ' || coalesce(v_order_number, new.order_id::text) ||
      '. Category: ' || replace(new.category, '_', ' ') || '.',
      new.order_id, new.id
    );
  elsif old.status is distinct from new.status then
    perform public.matrix_add_seller_notification(
      new.seller_id, 'dispute_update', 'Dispute status updated',
      'The dispute for order ' || coalesce(v_order_number, new.order_id::text) ||
      ' is now ' || replace(new.status, '_', ' ') || '.',
      new.order_id, new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists matrix_seller_dispute_activity_insert on public.matrix_order_disputes;
drop trigger if exists matrix_seller_dispute_activity_update on public.matrix_order_disputes;

create trigger matrix_seller_dispute_activity_insert
after insert on public.matrix_order_disputes
for each row execute function public.matrix_notify_seller_dispute_activity();

create trigger matrix_seller_dispute_activity_update
after update of status on public.matrix_order_disputes
for each row
when (old.status is distinct from new.status)
execute function public.matrix_notify_seller_dispute_activity();

-- Payout status changes (notification only; this does not initiate a transfer).
create or replace function public.matrix_notify_seller_payout_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_number text;
begin
  if old.status is distinct from new.status then
    select order_number into v_order_number
      from public.matrix_orders where id = new.order_id;
    perform public.matrix_add_seller_notification(
      new.seller_id, 'payout_update', 'Payout status updated',
      'Payout for order ' || coalesce(v_order_number, new.order_id::text) ||
      ' is now ' || replace(new.status, '_', ' ') || '.',
      new.order_id, new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists matrix_seller_payout_activity_update on public.matrix_seller_payouts;
create trigger matrix_seller_payout_activity_update
after update of status on public.matrix_seller_payouts
for each row
when (old.status is distinct from new.status)
execute function public.matrix_notify_seller_payout_activity();

revoke all on function public.matrix_notify_seller_order_activity() from public, anon, authenticated;
revoke all on function public.matrix_notify_seller_pickup_activity() from public, anon, authenticated;
revoke all on function public.matrix_notify_seller_dispute_activity() from public, anon, authenticated;
revoke all on function public.matrix_notify_seller_payout_activity() from public, anon, authenticated;
