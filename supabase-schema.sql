-- FairShare database schema for Supabase
-- Run this ONCE in Supabase Dashboard -> SQL Editor -> New query.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  email text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (sender_id <> receiver_id)
);
create unique index if not exists friend_request_pair_pending_idx on public.friend_requests (least(sender_id,receiver_id), greatest(sender_id,receiver_id)) where status='pending';

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id,user_id)
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  description text not null,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null default 'IDR',
  paid_by uuid not null references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.expense_splits (
  expense_id uuid not null references public.expenses(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount numeric(14,2) not null check (amount >= 0),
  primary key (expense_id,user_id)
);

create table if not exists public.settlements (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  from_user uuid not null references public.profiles(id),
  to_user uuid not null references public.profiles(id),
  amount numeric(14,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  check (from_user <> to_user)
);

-- Automatically create/update a public profile when an auth user signs up.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id,display_name,email)
  values(new.id, coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1)), lower(new.email))
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of email on auth.users
for each row execute function public.handle_new_user();

-- Helper: group membership check avoids recursive RLS policies.
create or replace function public.is_group_member(gid uuid, uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.group_members gm where gm.group_id=gid and gm.user_id=uid);
$$;

-- Exact-email search + friend request, without exposing the whole user directory.
create or replace function public.send_friend_request(target_email text) returns text
language plpgsql security definer set search_path=public as $$
declare target uuid; existing text;
begin
  select id into target from public.profiles where lower(email)=lower(trim(target_email));
  if target is null then raise exception 'No FairShare user found with that email'; end if;
  if target=auth.uid() then raise exception 'You cannot add yourself'; end if;
  if exists(select 1 from public.friend_requests where status='accepted' and ((sender_id=auth.uid() and receiver_id=target) or (receiver_id=auth.uid() and sender_id=target))) then return 'You are already friends'; end if;
  if exists(select 1 from public.friend_requests where status='pending' and ((sender_id=auth.uid() and receiver_id=target) or (receiver_id=auth.uid() and sender_id=target))) then return 'A friend request is already pending'; end if;
  insert into public.friend_requests(sender_id,receiver_id) values(auth.uid(),target);
  return 'Friend request sent';
end; $$;

create or replace function public.get_my_friends() returns table(id uuid,display_name text,email text)
language sql stable security definer set search_path=public as $$
  select p.id,p.display_name,p.email
  from public.profiles p
  join public.friend_requests f on f.status='accepted' and ((f.sender_id=auth.uid() and f.receiver_id=p.id) or (f.receiver_id=auth.uid() and f.sender_id=p.id))
  order by p.display_name;
$$;

create or replace function public.get_my_groups() returns table(id uuid,name text,description text,member_count bigint,created_at timestamptz)
language sql stable security definer set search_path=public as $$
  select g.id,g.name,g.description,count(gm2.user_id),g.created_at
  from public.groups g
  join public.group_members mine on mine.group_id=g.id and mine.user_id=auth.uid()
  join public.group_members gm2 on gm2.group_id=g.id
  group by g.id order by g.created_at desc;
$$;

create or replace function public.create_group_with_members(group_name text, group_description text, member_ids uuid[]) returns uuid
language plpgsql security definer set search_path=public as $$
declare gid uuid; mid uuid;
begin
  insert into public.groups(name,description,created_by) values(trim(group_name),nullif(trim(group_description),''),auth.uid()) returning id into gid;
  insert into public.group_members(group_id,user_id) values(gid,auth.uid());
  foreach mid in array coalesce(member_ids,'{}'::uuid[]) loop
    if exists(select 1 from public.friend_requests where status='accepted' and ((sender_id=auth.uid() and receiver_id=mid) or (receiver_id=auth.uid() and sender_id=mid))) then
      insert into public.group_members(group_id,user_id) values(gid,mid) on conflict do nothing;
    end if;
  end loop;
  return gid;
end; $$;

create or replace function public.add_group_members(target_group_id uuid, member_ids uuid[]) returns void
language plpgsql security definer set search_path=public as $$
declare mid uuid;
begin
  if not public.is_group_member(target_group_id) then raise exception 'Not a member of this group'; end if;
  foreach mid in array coalesce(member_ids,'{}'::uuid[]) loop
    if exists(select 1 from public.friend_requests where status='accepted' and ((sender_id=auth.uid() and receiver_id=mid) or (receiver_id=auth.uid() and sender_id=mid))) then
      insert into public.group_members(group_id,user_id) values(target_group_id,mid) on conflict do nothing;
    end if;
  end loop;
end; $$;

create or replace function public.create_equal_expense(target_group_id uuid, expense_description text, expense_amount numeric, payer_id uuid, participant_ids uuid[]) returns uuid
language plpgsql security definer set search_path=public as $$
declare eid uuid; uid uuid; n int; each_amount numeric; running numeric:=0; idx int:=0;
begin
  if not public.is_group_member(target_group_id) then raise exception 'Not a member of this group'; end if;
  if not public.is_group_member(target_group_id,payer_id) then raise exception 'Payer is not in the group'; end if;
  n:=coalesce(array_length(participant_ids,1),0); if n<1 then raise exception 'Choose at least one participant'; end if;
  foreach uid in array participant_ids loop if not public.is_group_member(target_group_id,uid) then raise exception 'A participant is not in the group'; end if; end loop;
  insert into public.expenses(group_id,description,amount,paid_by,created_by) values(target_group_id,trim(expense_description),expense_amount,payer_id,auth.uid()) returning id into eid;
  each_amount:=trunc((expense_amount/n)::numeric,2);
  foreach uid in array participant_ids loop
    idx:=idx+1;
    if idx=n then insert into public.expense_splits values(eid,uid,expense_amount-running); else insert into public.expense_splits values(eid,uid,each_amount); running:=running+each_amount; end if;
  end loop;
  return eid;
end; $$;

alter table public.profiles enable row level security;
alter table public.friend_requests enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_splits enable row level security;
alter table public.settlements enable row level security;

-- Profiles: users can see themselves and fellow group members / parties to friend requests.
create policy "profile self" on public.profiles for select using(id=auth.uid());
create policy "profile related" on public.profiles for select using(
  exists(select 1 from public.group_members a join public.group_members b on a.group_id=b.group_id where a.user_id=auth.uid() and b.user_id=profiles.id)
  or exists(select 1 from public.friend_requests f where (f.sender_id=auth.uid() and f.receiver_id=profiles.id) or (f.receiver_id=auth.uid() and f.sender_id=profiles.id))
);
create policy "profile update self" on public.profiles for update using(id=auth.uid()) with check(id=auth.uid());

create policy "friend request parties read" on public.friend_requests for select using(sender_id=auth.uid() or receiver_id=auth.uid());
create policy "friend request receiver update" on public.friend_requests for update using(receiver_id=auth.uid()) with check(receiver_id=auth.uid());

create policy "group members read groups" on public.groups for select using(public.is_group_member(id));
create policy "group members read membership" on public.group_members for select using(public.is_group_member(group_id));

create policy "group members read expenses" on public.expenses for select using(public.is_group_member(group_id));
create policy "group members read splits" on public.expense_splits for select using(exists(select 1 from public.expenses e where e.id=expense_id and public.is_group_member(e.group_id)));

create policy "group members read settlements" on public.settlements for select using(public.is_group_member(group_id));
create policy "payer can record own settlement" on public.settlements for insert with check(public.is_group_member(group_id) and from_user=auth.uid() and public.is_group_member(group_id,to_user));

-- RPC execution grants for logged-in users.
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.get_my_friends() to authenticated;
grant execute on function public.get_my_groups() to authenticated;
grant execute on function public.create_group_with_members(text,text,uuid[]) to authenticated;
grant execute on function public.add_group_members(uuid,uuid[]) to authenticated;
grant execute on function public.create_equal_expense(uuid,text,numeric,uuid,uuid[]) to authenticated;
grant execute on function public.is_group_member(uuid,uuid) to authenticated;
