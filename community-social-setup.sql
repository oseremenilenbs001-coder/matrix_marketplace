-- Matrix social features: friend requests, private inbox, blocking and reports
create table if not exists public.friend_requests (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references public.community_profiles(user_id) on delete cascade,
 recipient_id uuid not null references public.community_profiles(user_id) on delete cascade,
 status text not null default 'pending' check (status in ('pending','accepted','declined')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint no_self_friend_request check (sender_id <> recipient_id),
 constraint unique_friend_pair unique(sender_id,recipient_id)
);
alter table public.friend_requests enable row level security;
drop policy if exists "Users view their friend requests" on public.friend_requests;
create policy "Users view their friend requests" on public.friend_requests for select to authenticated using (auth.uid()=sender_id or auth.uid()=recipient_id);
drop policy if exists "Users send friend requests" on public.friend_requests;
create policy "Users send friend requests" on public.friend_requests for insert to authenticated with check (auth.uid()=sender_id and recipient_id<>auth.uid() and status='pending');
drop policy if exists "Recipients respond to friend requests" on public.friend_requests;
create policy "Recipients respond to friend requests" on public.friend_requests for update to authenticated using (auth.uid()=recipient_id and status='pending') with check (auth.uid()=recipient_id and status in ('accepted','declined'));
grant select,insert,update on public.friend_requests to authenticated;

create table if not exists public.direct_messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references public.community_profiles(user_id) on delete cascade,
 recipient_id uuid not null references public.community_profiles(user_id) on delete cascade,
 body text not null check (char_length(trim(body)) between 1 and 2000),
 created_at timestamptz not null default now(),
 constraint dm_not_self check (sender_id<>recipient_id)
);
alter table public.direct_messages enable row level security;
drop policy if exists "Friends read their private messages" on public.direct_messages;
create policy "Friends read their private messages" on public.direct_messages for select to authenticated using (
 (auth.uid()=sender_id or auth.uid()=recipient_id)
 and exists(select 1 from public.friend_requests f where f.status='accepted' and ((f.sender_id=direct_messages.sender_id and f.recipient_id=direct_messages.recipient_id) or (f.sender_id=direct_messages.recipient_id and f.recipient_id=direct_messages.sender_id)))
 and not exists(select 1 from public.user_blocks b where (b.blocker_id=direct_messages.sender_id and b.blocked_id=direct_messages.recipient_id) or (b.blocker_id=direct_messages.recipient_id and b.blocked_id=direct_messages.sender_id))
);
drop policy if exists "Friends send private messages" on public.direct_messages;
create policy "Friends send private messages" on public.direct_messages for insert to authenticated with check (
 auth.uid()=sender_id and exists(select 1 from public.friend_requests f where f.status='accepted' and ((f.sender_id=sender_id and f.recipient_id=direct_messages.recipient_id) or (f.sender_id=direct_messages.recipient_id and f.recipient_id=sender_id)))
 and not exists(select 1 from public.user_blocks b where (b.blocker_id=sender_id and b.blocked_id=recipient_id) or (b.blocker_id=recipient_id and b.blocked_id=sender_id))
);
grant select,insert on public.direct_messages to authenticated;

create table if not exists public.user_blocks (
 blocker_id uuid not null references public.community_profiles(user_id) on delete cascade,
 blocked_id uuid not null references public.community_profiles(user_id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(blocker_id,blocked_id),
 constraint no_self_block check(blocker_id<>blocked_id)
);
alter table public.user_blocks enable row level security;
drop policy if exists "Users view their own blocks" on public.user_blocks;
create policy "Users view their own blocks" on public.user_blocks for select to authenticated using(auth.uid()=blocker_id);
drop policy if exists "Users block others" on public.user_blocks;
create policy "Users block others" on public.user_blocks for insert to authenticated with check(auth.uid()=blocker_id);
drop policy if exists "Users unblock others" on public.user_blocks;
create policy "Users unblock others" on public.user_blocks for delete to authenticated using(auth.uid()=blocker_id);
grant select,insert,delete on public.user_blocks to authenticated;

create table if not exists public.community_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references public.community_profiles(user_id) on delete cascade,
 reported_user_id uuid references public.community_profiles(user_id) on delete set null,
 post_id uuid references public.community_posts(id) on delete set null,
 message_id uuid references public.direct_messages(id) on delete set null,
 reason text not null check(char_length(trim(reason)) between 3 and 500),
 created_at timestamptz not null default now()
);
alter table public.community_reports enable row level security;
drop policy if exists "Users submit reports" on public.community_reports;
create policy "Users submit reports" on public.community_reports for insert to authenticated with check(auth.uid()=reporter_id);
drop policy if exists "Users view their submitted reports" on public.community_reports;
create policy "Users view their submitted reports" on public.community_reports for select to authenticated using(auth.uid()=reporter_id);
grant select,insert on public.community_reports to authenticated;
