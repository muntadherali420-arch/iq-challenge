-- Server-enforced puzzle round limit: 10 puzzles, then a 30-minute break.
-- The state table is private; authenticated users interact only through guarded RPCs.

create table if not exists public.puzzle_round_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  round_question_ids uuid[] not null default '{}'::uuid[],
  answered_question_ids uuid[] not null default '{}'::uuid[],
  cooldown_until timestamptz,
  round_started_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.puzzle_round_state enable row level security;
revoke all on table public.puzzle_round_state from public, anon, authenticated;

create or replace function public.get_puzzle_round_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_state public.puzzle_round_state%rowtype;
  v_answered integer := 0;
  v_round_size integer := 0;
  v_remaining integer := 0;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  select * into v_state
  from public.puzzle_round_state
  where user_id = v_user_id;

  if not found then
    return jsonb_build_object(
      'cooldown_until', null,
      'remaining_seconds', 0,
      'answered_count', 0,
      'round_size', 10,
      'round_active', false
    );
  end if;

  v_answered := cardinality(coalesce(v_state.answered_question_ids, '{}'::uuid[]));
  v_round_size := cardinality(coalesce(v_state.round_question_ids, '{}'::uuid[]));

  if v_state.cooldown_until is not null and v_state.cooldown_until > now() then
    v_remaining := greatest(0, ceil(extract(epoch from (v_state.cooldown_until - now())))::integer);
  end if;

  return jsonb_build_object(
    'cooldown_until', v_state.cooldown_until,
    'remaining_seconds', v_remaining,
    'answered_count', v_answered,
    'round_size', case when v_round_size > 0 then v_round_size else 10 end,
    'round_active', v_round_size > v_answered and v_remaining = 0
  );
end;
$function$;

create or replace function public.get_puzzle_questions()
returns table(
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
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_state public.puzzle_round_state%rowtype;
  v_question_ids uuid[];
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  insert into public.puzzle_round_state(user_id)
  values (v_user_id)
  on conflict (user_id) do nothing;

  select * into v_state
  from public.puzzle_round_state
  where user_id = v_user_id
  for update;

  if v_state.cooldown_until is not null and v_state.cooldown_until > now() then
    raise exception 'استراحة الأحجيات ما زالت مستمرة. حاول بعد انتهاء المؤقت.';
  end if;

  if cardinality(v_state.round_question_ids) = 0
     or cardinality(v_state.answered_question_ids) >= cardinality(v_state.round_question_ids) then
    select coalesce(array_agg(picked.id), '{}'::uuid[])
    into v_question_ids
    from (
      select q.id
      from public.questions q
      where q.is_active = true
        and q.category = 'ألغاز وأحجيات مخادعة'
        and not exists (
          select 1
          from public.question_attempts a
          where a.user_id = v_user_id
            and a.question_id = q.id
        )
      order by random()
      limit 10
    ) picked;

    if cardinality(v_question_ids) = 0 then
      return;
    end if;

    update public.puzzle_round_state
    set round_question_ids = v_question_ids,
        answered_question_ids = '{}'::uuid[],
        round_started_at = now(),
        cooldown_until = null,
        updated_at = now()
    where user_id = v_user_id;

    select * into v_state
    from public.puzzle_round_state
    where user_id = v_user_id;
  end if;

  return query
  select q.id, q.question_text, q.option_a, q.option_b, q.option_c, q.option_d,
         q.category, q.difficulty
  from public.questions q
  where q.is_active = true
    and q.id = any(v_state.round_question_ids)
    and not (q.id = any(v_state.answered_question_ids))
  order by array_position(v_state.round_question_ids, q.id);
end;
$function$;

create or replace function public.submit_question_answer(
  p_question_id uuid,
  p_selected_option text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_selected text := upper(coalesce(p_selected_option, ''));
  v_correct text;
  v_explanation text;
  v_category text;
  v_is_correct boolean;
  v_rows integer;
  v_total_score integer;
  v_answered_count integer;
  v_puzzle_state public.puzzle_round_state%rowtype;
  v_puzzle_answered_ids uuid[];
  v_puzzle_answered_count integer := 0;
  v_puzzle_round_size integer := 0;
  v_cooldown_until timestamptz;
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

  select q.correct_option, coalesce(q.explanation, ''), q.category
  into v_correct, v_explanation, v_category
  from public.questions q
  where q.id = p_question_id and q.is_active = true;

  if not found then
    raise exception 'السؤال غير موجود أو غير نشط';
  end if;

  if v_category = 'ألغاز وأحجيات مخادعة' then
    select * into v_puzzle_state
    from public.puzzle_round_state
    where user_id = v_user_id
    for update;

    if not found or not (p_question_id = any(v_puzzle_state.round_question_ids)) then
      raise exception 'هذا اللغز ليس ضمن الجولة الحالية. أعد تحميل الأحجيات.';
    end if;

    if v_puzzle_state.cooldown_until is not null and v_puzzle_state.cooldown_until > now() then
      raise exception 'انتهت محاولات الجولة وبدأت الاستراحة. حاول بعد انتهاء المؤقت.';
    end if;
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

  if v_category = 'ألغاز وأحجيات مخادعة' then
    v_puzzle_answered_ids := array_append(
      coalesce(v_puzzle_state.answered_question_ids, '{}'::uuid[]),
      p_question_id
    );
    v_puzzle_answered_count := cardinality(v_puzzle_answered_ids);
    v_puzzle_round_size := cardinality(v_puzzle_state.round_question_ids);

    if v_puzzle_round_size > 0 and v_puzzle_answered_count >= v_puzzle_round_size then
      v_cooldown_until := now() + interval '30 minutes';
    else
      v_cooldown_until := null;
    end if;

    update public.puzzle_round_state
    set answered_question_ids = v_puzzle_answered_ids,
        cooldown_until = v_cooldown_until,
        updated_at = now()
    where user_id = v_user_id;
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
    'answered_count', v_answered_count,
    'puzzle_round_answered_count', v_puzzle_answered_count,
    'puzzle_round_size', v_puzzle_round_size,
    'puzzle_cooldown_until', v_cooldown_until
  );
end;
$function$;

revoke all on function public.get_puzzle_round_status() from public, anon;
revoke all on function public.get_puzzle_questions() from public, anon;
revoke all on function public.submit_question_answer(uuid, text) from public, anon;

grant execute on function public.get_puzzle_round_status() to authenticated;
grant execute on function public.get_puzzle_questions() to authenticated;
grant execute on function public.submit_question_answer(uuid, text) to authenticated;
