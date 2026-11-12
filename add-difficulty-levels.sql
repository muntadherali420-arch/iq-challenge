-- IQ Challenge: difficulty-filtered question loading
-- Run this migration once in Supabase SQL Editor.

create or replace function public.get_quiz_questions_by_difficulty(p_difficulty text default 'all')
returns table (
  id uuid,
  question_text text,
  option_a text,
  option_b text,
  option_c text,
  option_d text,
  category text,
  difficulty text
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

  if p_difficulty is null or p_difficulty not in ('all','easy','medium','hard','expert','genius') then
    raise exception 'مستوى الصعوبة غير صالح';
  end if;

  return query
  select q.id, q.question_text, q.option_a, q.option_b,
         q.option_c, q.option_d, q.category, q.difficulty
  from public.questions q
  where q.is_active = true
    and (p_difficulty = 'all' or q.difficulty = p_difficulty)
    and not exists (
      select 1 from public.question_attempts a
      where a.user_id = v_user_id and a.question_id = q.id
    )
  order by random()
  limit 5;
end;
$$;

revoke all on function public.get_quiz_questions_by_difficulty(text) from public, anon;
grant execute on function public.get_quiz_questions_by_difficulty(text) to authenticated;
