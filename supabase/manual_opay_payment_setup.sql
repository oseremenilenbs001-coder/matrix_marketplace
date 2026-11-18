-- Matrix Marketplace: temporary manual OPay checkout.
-- Run this file in Supabase SQL Editor. Do NOT put bank details in GitHub.
create table if not exists public.matrix_payment_settings (
  id boolean primary key default true check (id),
  account_name text not null,
  account_number text not null,
  bank_name text not null default 'OPay',
  instructions text not null default 'Transfer the exact amount shown. Your order is marked paid only after the transfer is checked in the account.',
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.matrix_payment_settings enable row level security;
revoke all on public.matrix_payment_settings from anon, authenticated;
drop policy if exists "Buyers can read active payment instructions" on public.matrix_payment_settings;
create policy "Buyers can read active payment instructions"
on public.matrix_payment_settings for select to authenticated using (is_active=true);
grant select on public.matrix_payment_settings to authenticated;

create table if not exists public.matrix_manual_payment_submissions (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.matrix_orders(id) on delete restrict,
  buyer_id uuid not null references auth.users(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  sender_name text not null,
  transfer_reference text not null unique,
  buyer_note text,
  status text not null default 'pending' check (status in ('pending','verified','rejected')),
  admin_note text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.matrix_manual_payment_submissions enable row level security;
revoke all on public.matrix_manual_payment_submissions from anon, authenticated;
grant select,insert on public.matrix_manual_payment_submissions to authenticated;
drop policy if exists "Buyers view own manual payment submissions" on public.matrix_manual_payment_submissions;
create policy "Buyers view own manual payment submissions"
on public.matrix_manual_payment_submissions for select to authenticated
using (buyer_id=auth.uid() or public.matrix_is_admin());
drop policy if exists "Buyers submit payment reference for own unpaid order" on public.matrix_manual_payment_submissions;
create policy "Buyers submit payment reference for own unpaid order"
on public.matrix_manual_payment_submissions for insert to authenticated
with check (
 buyer_id=auth.uid()
 and exists (
  select 1 from public.matrix_orders o
  where o.id=order_id and o.buyer_id=auth.uid()
    and o.status='awaiting_payment' and o.payment_status='pending'
    and o.total_amount=amount
    and o.created_at > now()-interval '30 minutes'
 )
 and length(trim(sender_name)) between 2 and 100
 and length(trim(transfer_reference)) between 4 and 120
);

create or replace function public.matrix_admin_review_manual_payment(
 p_submission_id uuid, p_decision text, p_admin_note text default null
) returns void language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v public.matrix_manual_payment_submissions%rowtype; o public.matrix_orders%rowtype;
begin
 if not public.matrix_is_admin() then raise exception 'Administrator access required.'; end if;
 if p_decision not in ('verified','rejected') then raise exception 'Choose verified or rejected.'; end if;
 select * into v from public.matrix_manual_payment_submissions where id=p_submission_id for update;
 if not found or v.status<>'pending' then raise exception 'Pending payment submission not found.'; end if;
 select * into o from public.matrix_orders where id=v.order_id for update;
 if not found or o.buyer_id<>v.buyer_id or o.status<>'awaiting_payment' or o.payment_status<>'pending' then
   raise exception 'The order is no longer eligible for payment verification.';
 end if;
 if v.amount<>o.total_amount then raise exception 'Submitted amount does not match the order total.'; end if;
 update public.matrix_manual_payment_submissions
 set status=p_decision,admin_note=nullif(left(trim(coalesce(p_admin_note,'')),500),''),reviewed_by=auth.uid(),reviewed_at=now()
 where id=v.id;
 if p_decision='verified' then
   update public.matrix_orders set payment_status='paid',status='paid',updated_at=now() where id=o.id;
   update public.matrix_payments set provider='opay_manual',provider_reference=v.transfer_reference,status='successful',verified_at=now(),updated_at=now()
   where order_id=o.id and status='pending';
 else
   -- Rejection leaves the order unpaid; buyer can contact support before expiry.
   null;
 end if;
end; $$;
revoke all on function public.matrix_admin_review_manual_payment(uuid,text,text) from public,anon;
grant execute on function public.matrix_admin_review_manual_payment(uuid,text,text) to authenticated;

-- Add/update the account details privately in Supabase SQL Editor after running this migration:
-- insert into public.matrix_payment_settings(id,account_name,account_number,bank_name,is_active)
-- values(true,'YOUR ACCOUNT NAME','YOUR ACCOUNT NUMBER','OPay',true)
-- on conflict(id) do update set account_name=excluded.account_name,
-- account_number=excluded.account_number,bank_name=excluded.bank_name,
-- is_active=true,updated_at=now();
