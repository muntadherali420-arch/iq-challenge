-- Keep player totals consistent across normal questions and daily challenges.
-- Apply with Supabase SQL Editor if deploying this function to another project.

create or replace function public.submit_question_answer(
  p_question_id uuid,
  p_selected_option text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_selected text := upper(coalesce(p_selected_option, ''));
  v_correct text;
  v_explanation text;
  v_is_correct boolean;
  v_rows integer;
  v_total_score integer;
  v_answered_count integer;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  if v_selected not in ('A','B','C','D') then
    raise exception 'الخيار المحدد غير صالح';
  end if;

  if exists (
    select 1 from public.question_attempts
    where user_id = v_user_id and question_id = p_question_id
  ) then
    select
      coalesce((select sum(points_awarded) from public.question_attempts where user_id = v_user_id), 0)
        + coalesce((select sum(points_awarded) from public.challenge_answers where user_id = v_user_id), 0),
      (select count(*) from public.question_attempts where user_id = v_user_id)
        + (select count(*) from public.challenge_answers where user_id = v_user_id)
    into v_total_score, v_answered_count;

    return jsonb_build_object(
      'already_answered', true,
      'total_score', v_total_score,
      'answered_count', v_answered_count
    );
  end if;

  select q.correct_option, coalesce(q.explanation, '')
  into v_correct, v_explanation
  from public.questions q
  where q.id = p_question_id and q.is_active = true;

  if not found then
    raise exception 'السؤال غير موجود أو غير نشط';
  end if;

  v_is_correct := (v_selected = v_correct);

  insert into public.question_attempts
    (user_id, question_id, selected_option, is_correct, points_awarded)
  values
    (v_user_id, p_question_id, v_selected, v_is_correct,
     case when v_is_correct then 10 else 0 end)
  on conflict (user_id, question_id) do nothing;

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'تم إرسال إجابة هذا السؤال مسبقاً';
  end if;

  select
    coalesce((select sum(points_awarded) from public.question_attempts where user_id = v_user_id), 0)
      + coalesce((select sum(points_awarded) from public.challenge_answers where user_id = v_user_id), 0),
    (select count(*) from public.question_attempts where user_id = v_user_id)
      + (select count(*) from public.challenge_answers where user_id = v_user_id)
  into v_total_score, v_answered_count;

  return jsonb_build_object(
    'already_answered', false,
    'is_correct', v_is_correct,
    'correct_option', v_correct,
    'explanation', v_explanation,
    'points_awarded', case when v_is_correct then 10 else 0 end,
    'total_score', v_total_score,
    'answered_count', v_answered_count
  );
end;
$function$;
