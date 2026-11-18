-- Matrix Marketplace Community: pseudonymous profiles, public feed and shared chat
create table if not exists public.community_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  nickname text not null check (char_length(nickname) between 2 and 30),
  avatar_url text,
  bio text check (char_length(coalesce(bio,'')) <= 160),
  updated_at timestamptz not null default now()
);
alter table public.community_profiles enable row level security;
drop policy if exists "Community profiles are public" on public.community_profiles;
create policy "Community profiles are public" on public.community_profiles for select to authenticated using (true);
drop policy if exists "Users create own community profile" on public.community_profiles;
create policy "Users create own community profile" on public.community_profiles for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "Users update own community profile" on public.community_profiles;
create policy "Users update own community profile" on public.community_profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update on public.community_profiles to authenticated;

create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.community_profiles(user_id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1200),
  created_at timestamptz not null default now()
);
alter table public.community_posts enable row level security;
drop policy if exists "Signed in users read community posts" on public.community_posts;
create policy "Signed in users read community posts" on public.community_posts for select to authenticated using (true);
drop policy if exists "Users create own community posts" on public.community_posts;
create policy "Users create own community posts" on public.community_posts for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "Users delete own community posts" on public.community_posts;
create policy "Users delete own community posts" on public.community_posts for delete to authenticated using (auth.uid() = user_id);
grant select, insert, delete on public.community_posts to authenticated;

create table if not exists public.community_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.community_profiles(user_id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now()
);
alter table public.community_messages enable row level security;
drop policy if exists "Signed in users read community chat" on public.community_messages;
create policy "Signed in users read community chat" on public.community_messages for select to authenticated using (true);
drop policy if exists "Users send own community messages" on public.community_messages;
create policy "Users send own community messages" on public.community_messages for insert to authenticated with check (auth.uid() = user_id);
grant select, insert on public.community_messages to authenticated;

insert into storage.buckets (id, name, public)
values ('profile-avatars', 'profile-avatars', true)
on conflict (id) do update set public = true;
drop policy if exists "Public can view community avatars" on storage.objects;
create policy "Public can view community avatars" on storage.objects for select using (bucket_id = 'profile-avatars');
drop policy if exists "Users upload own community avatar" on storage.objects;
create policy "Users upload own community avatar" on storage.objects for insert to authenticated
with check (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "Users update own community avatar" on storage.objects;
create policy "Users update own community avatar" on storage.objects for update to authenticated
using (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text)
with check (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
