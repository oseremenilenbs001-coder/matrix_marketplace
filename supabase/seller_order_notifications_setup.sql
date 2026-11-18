-- Matrix Marketplace: seller order notifications and read/unread history.
-- Run once in Supabase SQL Editor.

create table if not exists public.matrix_seller_notifications (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  order_id uuid not null references public.matrix_orders(id) on delete cascade,
  notification_type text not null default 'new_order' check (notification_type = 'new_order'),
  title text not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists matrix_seller_notifications_seller_created_idx
  on public.matrix_seller_notifications(seller_id, created_at desc);
create index if not exists matrix_seller_notifications_unread_idx
  on public.matrix_seller_notifications(seller_id, read_at)
  where read_at is null;

alter table public.matrix_seller_notifications enable row level security;

drop policy if exists "Sellers can view their own notifications" on public.matrix_seller_notifications;
create policy "Sellers can view their own notifications"
on public.matrix_seller_notifications
for select to authenticated
using (seller_id = auth.uid());

drop policy if exists "Sellers can mark their own notifications read" on public.matrix_seller_notifications;
create policy "Sellers can mark their own notifications read"
on public.matrix_seller_notifications
for update to authenticated
using (seller_id = auth.uid())
with check (seller_id = auth.uid());

revoke all on public.matrix_seller_notifications from anon, authenticated;
grant select on public.matrix_seller_notifications to authenticated;
grant update (read_at) on public.matrix_seller_notifications to authenticated;

create or replace function public.matrix_notify_seller_new_order()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item_summary text;
begin
  select string_agg(item.product_title || ' × ' || item.quantity::text, ', ' order by item.created_at)
  into v_item_summary
  from public.matrix_order_items item
  where item.order_id = new.id;

  insert into public.matrix_seller_notifications
    (seller_id, order_id, title, message)
  values
    (new.seller_id, new.id, 'New order received',
     'Order ' || new.order_number || ' · ' || coalesce(v_item_summary, 'New items') ||
     ' · ₦' || to_char(new.total_amount, 'FM999,999,990.00'));

  return new;
end;
$$;

drop trigger if exists matrix_order_seller_notification on public.matrix_orders;
create trigger matrix_order_seller_notification
after insert on public.matrix_orders
for each row execute function public.matrix_notify_seller_new_order();

revoke all on function public.matrix_notify_seller_new_order() from public, anon, authenticated;

-- Notifications are created only by the database trigger. Browsers cannot
-- create, delete, or change notification ownership/order details.
