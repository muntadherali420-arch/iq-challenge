-- IQ Challenge: secure server-side quiz and scoring
-- Run this entire file once in the Supabase SQL Editor.

create table if not exists public.question_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  selected_option text not null check (selected_option in ('A','B','C','D')),
  is_correct boolean not null,
  points_awarded integer not null default 0 check (points_awarded in (0,10)),
  created_at timestamptz not null default now(),
  constraint question_attempts_one_per_user unique (user_id, question_id)
);

alter table public.question_attempts enable row level security;
revoke all on table public.question_attempts from anon, authenticated;
revoke select on table public.questions from anon, authenticated;

create or replace function public.get_quiz_questions()
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

  return query
  select q.id, q.question_text, q.option_a, q.option_b,
         q.option_c, q.option_d, q.category, q.difficulty
  from public.questions q
  where q.is_active = true
    and not exists (
      select 1 from public.question_attempts a
      where a.user_id = v_user_id and a.question_id = q.id
    )
  order by random()
  limit 5;
end;
$$;

create or replace function public.submit_question_answer(
  p_question_id uuid,
  p_selected_option text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    select coalesce(sum(points_awarded),0), count(*)
      into v_total_score, v_answered_count
    from public.question_attempts where user_id = v_user_id;

    return jsonb_build_object(
      'already_answered', true,
      'total_score', v_total_score,
      'answered_count', v_answered_count
    );
  end if;

  select q.correct_option, coalesce(q.explanation,'')
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

  select coalesce(sum(points_awarded),0), count(*)
    into v_total_score, v_answered_count
  from public.question_attempts where user_id = v_user_id;

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
$$;

revoke all on function public.get_quiz_questions() from public, anon;
revoke all on function public.submit_question_answer(uuid, text) from public, anon;
grant execute on function public.get_quiz_questions() to authenticated;
grant execute on function public.submit_question_answer(uuid, text) to authenticated;
