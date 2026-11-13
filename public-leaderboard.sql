-- IQ Challenge: allow a safe public top-20 leaderboard.
-- Exposes only display name, score, rank and answer count; never exposes emails or user IDs.
-- Run this migration in the Supabase SQL Editor after reviewing it.

create or replace function public.get_quiz_leaderboard()
returns table (
  rank_position bigint,
  username text,
  total_score bigint,
  answered_count bigint,
  is_me boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
begin
  return query
  with all_scores as (
    select user_id, points_awarded from public.question_attempts
    union all
    select user_id, points_awarded from public.challenge_answers
  ),
  totals as (
    select user_id,
           coalesce(sum(points_awarded), 0)::bigint as score,
           count(*)::bigint as answered
    from all_scores
    group by user_id
  ),
  ranked as (
    select t.user_id, t.score, t.answered,
           row_number() over (
             order by t.score desc, t.answered desc, t.user_id
           ) as place
    from totals t
  )
  select r.place,
         coalesce(nullif(left(p.username, 32), ''), 'لاعب')::text,
         r.score,
         r.answered,
         (r.user_id = v_user_id)
  from ranked r
  left join public.profiles p on p.id = r.user_id
  order by r.place
  limit 20;
end;
$$;

revoke all on function public.get_quiz_leaderboard() from public;
revoke all on function public.get_quiz_leaderboard() from anon;
grant execute on function public.get_quiz_leaderboard() to anon, authenticated;
