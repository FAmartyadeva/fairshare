-- FairShare upgrade: settlement tracker + allow either side to record repayment.
-- Run this ONCE in Supabase SQL Editor if you already ran the original schema.

alter table public.settlements
  add column if not exists recorded_by uuid references public.profiles(id);

drop policy if exists "payer can record own settlement" on public.settlements;
drop policy if exists "either party can record settlement" on public.settlements;

create policy "either party can record settlement"
on public.settlements
for insert
with check (
  public.is_group_member(group_id)
  and (from_user = auth.uid() or to_user = auth.uid())
  and public.is_group_member(group_id, from_user)
  and public.is_group_member(group_id, to_user)
  and (recorded_by is null or recorded_by = auth.uid())
);
