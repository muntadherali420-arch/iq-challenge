-- IQ Challenge: secure leaderboard (top 20)
-- Run once in Supabase SQL Editor.

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
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  return query
  with totals as (
    select a.user_id,
           coalesce(sum(a.points_awarded), 0)::bigint as score,
           count(*)::bigint as answered
    from public.question_attempts a
    group by a.user_id
  ),
  ranked as (
    select t.user_id, t.score, t.answered,
           row_number() over (order by t.score desc, t.answered desc, t.user_id) as place
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

revoke all on function public.get_quiz_leaderboard() from public, anon;
grant execute on function public.get_quiz_leaderboard() to authenticated;
