-- IQ Challenge: private admin dashboard permissions
-- Run this file in the Supabase SQL Editor as the project owner.
-- Then add the owner's Auth user UUID to public.admin_users (instructions below).

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

revoke all on table public.admin_users from anon, authenticated;
grant select on table public.admin_users to authenticated;

drop policy if exists "Admins can read their own admin grant" on public.admin_users;
create policy "Admins can read their own admin grant"
on public.admin_users
for select
to authenticated
using ((select auth.uid()) = user_id);

-- Questions remain readable to signed-in players only when active.
-- Only explicitly listed admin accounts can see inactive questions or write questions.
grant select, insert, update, delete on table public.questions to authenticated;

drop policy if exists "Admins manage all questions" on public.questions;
create policy "Admins manage all questions"
on public.questions
for all
to authenticated
using (
  exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  )
);

-- IMPORTANT: After creating your game account, find its UUID in
-- Supabase Dashboard -> Authentication -> Users, then run:
-- insert into public.admin_users (user_id)
-- values ('PASTE-YOUR-AUTH-USER-UUID-HERE');
--
-- Do not use user_metadata as an admin authorization source.
