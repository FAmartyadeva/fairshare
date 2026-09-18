-- FairShare V3 upgrade: group close/delete + remove friend.
-- Run this ONCE in Supabase SQL Editor after the earlier V2 settlement upgrade.
-- It is written to be safe if the group lifecycle columns/functions already exist.

alter table public.groups add column if not exists status text not null default 'active'
  check (status in ('active','closed'));
alter table public.groups add column if not exists closed_at timestamptz;
alter table public.groups add column if not exists closed_by uuid references public.profiles(id);

-- Return the metadata the frontend needs to show active/closed groups and owner controls.
drop function if exists public.get_my_groups();
create function public.get_my_groups()
returns table(
  id uuid,
  name text,
  description text,
  member_count bigint,
  created_at timestamptz,
  created_by uuid,
  status text,
  closed_at timestamptz
)
language sql stable security definer set search_path=public as $$
  select g.id,g.name,g.description,count(gm2.user_id),g.created_at,g.created_by,g.status,g.closed_at
  from public.groups g
  join public.group_members mine on mine.group_id=g.id and mine.user_id=auth.uid()
  join public.group_members gm2 on gm2.group_id=g.id
  group by g.id
  order by (g.status='closed'), g.created_at desc;
$$;

create or replace function public.close_group(target_group_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.groups where id=target_group_id and created_by=auth.uid()) then
    raise exception 'Only the group creator can close this group';
  end if;
  update public.groups
  set status='closed', closed_at=now(), closed_by=auth.uid()
  where id=target_group_id;
end; $$;

-- Deleting the group row permanently cascades through:
-- group_members -> group, expenses -> group, expense_splits -> expense, settlements -> group.
create or replace function public.delete_group(target_group_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.groups where id=target_group_id and created_by=auth.uid()) then
    raise exception 'Only the group creator can delete this group';
  end if;
  delete from public.groups where id=target_group_id;
end; $$;

-- Remove only the friendship. Existing shared groups and their financial history remain untouched.
create or replace function public.remove_friend(target_user_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if target_user_id is null or target_user_id=auth.uid() then
    raise exception 'Invalid friend';
  end if;
  if not exists(
    select 1 from public.friend_requests
    where status='accepted'
      and ((sender_id=auth.uid() and receiver_id=target_user_id)
        or (receiver_id=auth.uid() and sender_id=target_user_id))
  ) then
    raise exception 'This user is not in your friends list';
  end if;
  delete from public.friend_requests
  where (sender_id=auth.uid() and receiver_id=target_user_id)
     or (receiver_id=auth.uid() and sender_id=target_user_id);
end; $$;

-- Closed groups are read-only.
create or replace function public.add_group_members(target_group_id uuid, member_ids uuid[]) returns void
language plpgsql security definer set search_path=public as $$
declare mid uuid;
begin
  if not public.is_group_member(target_group_id) then raise exception 'Not a member of this group'; end if;
  if exists(select 1 from public.groups where id=target_group_id and status='closed') then raise exception 'This group is closed'; end if;
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
  if exists(select 1 from public.groups where id=target_group_id and status='closed') then raise exception 'This group is closed'; end if;
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

drop policy if exists "either party can record settlement" on public.settlements;
create policy "either party can record settlement"
on public.settlements
for insert
with check (
  public.is_group_member(group_id)
  and exists(select 1 from public.groups g where g.id=group_id and g.status='active')
  and (from_user=auth.uid() or to_user=auth.uid())
  and public.is_group_member(group_id,from_user)
  and public.is_group_member(group_id,to_user)
  and (recorded_by is null or recorded_by=auth.uid())
);

grant execute on function public.get_my_groups() to authenticated;
grant execute on function public.close_group(uuid) to authenticated;
grant execute on function public.delete_group(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.add_group_members(uuid,uuid[]) to authenticated;
grant execute on function public.create_equal_expense(uuid,text,numeric,uuid,uuid[]) to authenticated;
