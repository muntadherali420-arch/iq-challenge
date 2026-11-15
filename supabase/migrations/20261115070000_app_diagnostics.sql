create table if not exists public.app_diagnostics (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (event_type in (
    'app_boot',
    'session_ready',
    'auth_session_error',
    'question_load_error',
    'answer_submit_error',
    'daily_load_error',
    'daily_answer_error',
    'puzzle_answer_error',
    'startup_stats_error',
    'app_error',
    'promise_rejection',
    'network_offline'
  )),
  screen text check (screen is null or length(screen) <= 40),
  message text check (message is null or length(message) <= 500),
  details jsonb not null default '{}'::jsonb check (octet_length(details::text) <= 2000),
  app_version text not null default '0.1.0' check (length(app_version) <= 20),
  platform text not null default 'web' check (length(platform) <= 20),
  created_at timestamptz not null default now()
);

create index if not exists app_diagnostics_created_at_idx
  on public.app_diagnostics (created_at desc);
create index if not exists app_diagnostics_user_created_at_idx
  on public.app_diagnostics (user_id, created_at desc);

alter table public.app_diagnostics enable row level security;
revoke all on table public.app_diagnostics from public, anon, authenticated;
grant insert on table public.app_diagnostics to authenticated;
drop policy if exists "players can submit their own diagnostics" on public.app_diagnostics;
create policy "players can submit their own diagnostics"
  on public.app_diagnostics
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);
