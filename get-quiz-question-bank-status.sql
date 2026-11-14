-- Per-player question bank progress for the main quiz.
-- Excludes the dedicated puzzle category and questions already answered by this user.
create or replace function public.get_quiz_question_bank_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_total integer := 0;
  v_remaining integer := 0;
  v_by_difficulty jsonb := '{}'::jsonb;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  select count(*)::integer into v_total
  from public.questions q
  where q.is_active = true and q.category <> 'ألغاز وأحجيات مخادعة';

  select count(*)::integer into v_remaining
  from public.questions q
  where q.is_active = true
    and q.category <> 'ألغاز وأحجيات مخادعة'
    and not exists (
      select 1 from public.question_attempts a
      where a.user_id = v_user_id and a.question_id = q.id
    );

  select coalesce(jsonb_object_agg(difficulty, remaining), '{}'::jsonb)
    into v_by_difficulty
  from (
    select q.difficulty, count(*)::integer as remaining
    from public.questions q
    where q.is_active = true
      and q.category <> 'ألغاز وأحجيات مخادعة'
      and not exists (
        select 1 from public.question_attempts a
        where a.user_id = v_user_id and a.question_id = q.id
      )
    group by q.difficulty
  ) counts;

  return jsonb_build_object(
    'total_questions', v_total,
    'remaining_questions', v_remaining,
    'answered_questions', greatest(0, v_total - v_remaining),
    'remaining_by_difficulty', v_by_difficulty
  );
end;
$function$;

revoke all on function public.get_quiz_question_bank_status() from public, anon;
grant execute on function public.get_quiz_question_bank_status() to authenticated;
