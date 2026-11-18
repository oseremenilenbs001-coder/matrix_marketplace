-- Matrix Marketplace settings backend
-- Run this file once in the Supabase SQL Editor.
-- All rows are scoped to the signed-in user; no service-role key is used in the browser.

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  notify_messages boolean not null default true,
  notify_orders boolean not null default true,
  notify_community boolean not null default true,
  notify_marketing boolean not null default false,
  preferred_theme text not null default 'light'
    check (preferred_theme in ('light', 'dark', 'system')),
  text_size text not null default 'normal'
    check (text_size in ('normal', 'large', 'larger')),
  reduce_motion boolean not null default false,
  language text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;

drop policy if exists "Users can read their own settings" on public.user_settings;
create policy "Users can read their own settings"
  on public.user_settings for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Users can create their own settings" on public.user_settings;
create policy "Users can create their own settings"
  on public.user_settings for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Users can update their own settings" on public.user_settings;
create policy "Users can update their own settings"
  on public.user_settings for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create or replace function public.set_user_settings_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists user_settings_updated_at on public.user_settings;
create trigger user_settings_updated_at
before update on public.user_settings
for each row execute function public.set_user_settings_updated_at();

create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reason text,
  status text not null default 'pending'
    check (status in ('pending', 'reviewing', 'completed', 'rejected')),
  created_at timestamptz not null default now()
);

alter table public.account_deletion_requests enable row level security;

drop policy if exists "Users can view their own deletion requests" on public.account_deletion_requests;
create policy "Users can view their own deletion requests"
  on public.account_deletion_requests for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Users can submit their own deletion requests" on public.account_deletion_requests;
create policy "Users can submit their own deletion requests"
  on public.account_deletion_requests for insert
  to authenticated
  with check (auth.uid() = user_id);

-- Users cannot change request status or delete requests from the client.
revoke all on public.account_deletion_requests from anon, authenticated;
grant select, insert on public.account_deletion_requests to authenticated;
grant select, insert, update on public.user_settings to authenticated;
