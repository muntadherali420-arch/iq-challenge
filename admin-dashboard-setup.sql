-- IQ Challenge: private admin dashboard permissions
-- Run this file in the Supabase SQL Editor as the project owner.
-- Then add the owner's Auth user UUID to public.admin_users (instructions below).

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- A narrow, read-only check used by the dashboard. SECURITY INVOKER is intentional:
-- it respects the caller's RLS policies and cannot grant extra privileges.
create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
set search_path = ''
as $
  select exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  );
$;

revoke all on function public.is_current_user_admin() from public, anon;
grant execute on function public.is_current_user_admin() to authenticated;

alter table public.admin_users enable row level security;

revoke all on table public.admin_users from anon, authenticated;
grant select on table public.admin_users to authenticated;

drop policy if exists "Admins can read their own admin grant" on public.admin_users;
create policy "Admins can read their own admin grant"
on public.admin_users
for select
to authenticated
using ((select auth.uid()) = user_id);

-- Players can read active questions. Explicit admins can read all questions.
grant select, insert, update, delete on table public.questions to authenticated;

drop policy if exists "Authenticated users can read active questions" on public.questions;
drop policy if exists "Admins manage all questions" on public.questions;
drop policy if exists "Questions visible to players and admins" on public.questions;
create policy "Questions visible to players and admins"
on public.questions
for select
to authenticated
using (is_active = true or public.is_current_user_admin());

drop policy if exists "Admins insert questions" on public.questions;
create policy "Admins insert questions"
on public.questions
for insert
to authenticated
with check (public.is_current_user_admin());

drop policy if exists "Admins update questions" on public.questions;
create policy "Admins update questions"
on public.questions
for update
to authenticated
using (public.is_current_user_admin())
with check (public.is_current_user_admin());

drop policy if exists "Admins delete questions" on public.questions;
create policy "Admins delete questions"
on public.questions
for delete
to authenticated
using (public.is_current_user_admin());

-- IMPORTANT: After creating your game account, find its UUID in
-- Supabase Dashboard -> Authentication -> Users, then run:
-- insert into public.admin_users (user_id)
-- values ('PASTE-YOUR-AUTH-USER-UUID-HERE');
--
-- Do not use user_metadata as an admin authorization source.
