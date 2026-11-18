-- Matrix Marketplace: automatically expire unpaid orders after 30 minutes.
-- Run this migration once in the Supabase SQL Editor.
-- The scheduled task runs every 5 minutes; an order may therefore expire
-- between 30 and 35 minutes after creation.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.matrix_expire_unpaid_orders()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.matrix_orders%rowtype;
  v_item public.matrix_order_items%rowtype;
  v_expired_count integer := 0;
begin
  -- Lock each eligible order so expiry cannot race buyer cancellation or
  -- another expiry worker. Paid/otherwise-updated orders are never selected.
  for v_order in
    select *
    from public.matrix_orders
    where status = 'awaiting_payment'
      and payment_status = 'pending'
      and created_at <= now() - interval '30 minutes'
    order by created_at
    for update skip locked
  loop
    -- Restore reserved stock exactly once for each expired order.
    for v_item in
      select *
      from public.matrix_order_items
      where order_id = v_order.id
    loop
      if v_item.product_id is not null then
        update public.products
        set stock_quantity = stock_quantity + v_item.quantity
        where id = v_item.product_id;
      end if;
    end loop;

    update public.matrix_orders
    set status = 'cancelled',
        payment_status = 'failed',
        updated_at = now()
    where id = v_order.id
      and status = 'awaiting_payment'
      and payment_status = 'pending';

    update public.matrix_payments
    set status = 'failed',
        updated_at = now()
    where order_id = v_order.id
      and status = 'pending';

    update public.matrix_seller_payouts
    set status = 'cancelled',
        updated_at = now()
    where order_id = v_order.id
      and status = 'awaiting_delivery_confirmation';

    v_expired_count := v_expired_count + 1;
  end loop;

  return v_expired_count;
end;
$$;

-- Only the database scheduler/owner may execute this stock-restoring function.
revoke all on function public.matrix_expire_unpaid_orders() from public, anon, authenticated;

-- Replace any prior job with the same name, then schedule a single recurring job.
do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid from cron.job where jobname = 'matrix-expire-unpaid-orders'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'matrix-expire-unpaid-orders',
    '*/5 * * * *',
    'select public.matrix_expire_unpaid_orders();'
  );
end;
$$;

-- Payment-provider webhook requirement:
-- Before marking a payment successful, lock its order row and confirm that
-- status='awaiting_payment', payment_status='pending', and created_at is
-- newer than now()-interval '30 minutes'. Reject late payments for expired
-- orders and handle them through the provider's refund process; never revive
-- an expired order or trust a browser-supplied paid flag.
