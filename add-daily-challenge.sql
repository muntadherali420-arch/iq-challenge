-- IQ Challenge: secure daily challenge and bonus scoring
-- Run this file once in the Supabase SQL Editor.

alter table public.challenge_answers
  add column if not exists points_awarded integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.challenge_answers'::regclass
      and conname = 'challenge_answers_points_check'
  ) then
    alter table public.challenge_answers
      add constraint challenge_answers_points_check
      check (points_awarded in (0, 20));
  end if;
end $$;

alter table public.daily_challenges enable row level security;
alter table public.daily_challenge_keys enable row level security;
alter table public.challenge_answers enable row level security;

revoke all on public.daily_challenge_keys from anon, authenticated;
revoke all on public.challenge_answers from anon, authenticated;

-- A daily challenge is public, but its answer key is never exposed to clients.
create policy "Daily challenge keys are not directly readable"
  on public.daily_challenge_keys for select
  to anon, authenticated
  using (false);

-- Seed one challenge per day for the first seven days. Existing content is preserved.
insert into public.daily_challenges (challenge_date, question, options)
values
(date '2026-11-12', 'إذا كان 3 عمال ينجزون 3 قطع خلال 3 دقائق، فكم دقيقة يحتاج 6 عمال لإنجاز 6 قطع بالمعدل نفسه؟', '{"A":"3 دقائق","B":"6 دقائق","C":"9 دقائق","D":"12 دقيقة"}'::jsonb),
(date '2026-11-13', 'ما العدد التالي في السلسلة: 2، 6، 12، 20، 30، ؟', '{"A":"40","B":"42","C":"44","D":"46"}'::jsonb),
(date '2026-11-14', 'كل الورود أزهار، وبعض الأزهار تذبل سريعاً. هل نستنتج أن بعض الورود تذبل سريعاً؟', '{"A":"نعم بالتأكيد","B":"لا، لا تكفي المعلومات","C":"كل الورود تذبل","D":"لا توجد ورود"}'::jsonb),
(date '2026-11-15', 'إذا كانت 5 آلات تصنع 5 قطع في 5 دقائق، فكم دقيقة تحتاج 100 آلة لصنع 100 قطعة بالمعدل نفسه؟', '{"A":"5 دقائق","B":"20 دقيقة","C":"100 دقيقة","D":"500 دقيقة"}'::jsonb),
(date '2026-11-16', 'إذا كان اليوم الثلاثاء، فما اليوم بعد 100 يوم؟', '{"A":"الثلاثاء","B":"الأربعاء","C":"الخميس","D":"الجمعة"}'::jsonb),
(date '2026-11-17', 'ما العدد التالي في السلسلة: 1، 1، 2، 3، 5، 8، ؟', '{"A":"11","B":"13","C":"15","D":"16"}'::jsonb),
(date '2026-11-18', 'مكعب كبير مكوّن من 3×3×3 مكعبات صغيرة، ودُهنت أوجهه الخارجية كلها. كم مكعباً صغيراً له وجهان مدهونان بالضبط؟', '{"A":"8","B":"12","C":"6","D":"9"}'::jsonb)
on conflict (challenge_date) do nothing;

insert into public.daily_challenge_keys (challenge_id, correct_option, explanation)
select d.id, v.correct_option, v.explanation
from (values
  (date '2026-11-12', 'A', 'بما أن عدد العمال والقطع تضاعف معاً، تبقى المدة نفسها: 3 دقائق.'),
  (date '2026-11-13', 'B', 'الفروق هي 4 ثم 6 ثم 8 ثم 10؛ الفرق التالي 12، إذن 30 + 12 = 42.'),
  (date '2026-11-14', 'B', 'المعلومة تقول إن بعض الأزهار تذبل، لكنها لا تحدد أن هذه الأزهار من الورود.'),
  (date '2026-11-15', 'A', 'كل آلة تصنع قطعة واحدة خلال 5 دقائق؛ لذلك 100 آلة تصنع 100 قطعة في 5 دقائق.'),
  (date '2026-11-16', 'C', '100 يوماً تساوي 14 أسبوعاً ويتبقى يومان؛ الثلاثاء يصبح الخميس.'),
  (date '2026-11-17', 'B', 'كل عدد يساوي مجموع العددين السابقين: 5 + 8 = 13.'),
  (date '2026-11-18', 'B', 'المكعبات التي لها وجهان مدهونان تقع في منتصف حواف المكعب وعددها 12.')
) as v(challenge_date, correct_option, explanation)
join public.daily_challenges d on d.challenge_date = v.challenge_date
on conflict (challenge_id) do nothing;

create or replace function public.get_daily_challenge()
returns table (
  id uuid,
  challenge_date date,
  question text,
  options jsonb,
  already_answered boolean,
  selected_option text,
  points_awarded integer
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
  select d.id, d.challenge_date, d.question, d.options,
         (a.id is not null), a.selected_option, coalesce(a.points_awarded, 0)
  from public.daily_challenges d
  left join public.challenge_answers a
    on a.challenge_id = d.id and a.user_id = v_user_id
  where d.challenge_date = current_date
  limit 1;
end;
$$;

create or replace function public.submit_daily_challenge_answer(
  p_challenge_id uuid,
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
  v_date date;
  v_correct text;
  v_explanation text;
  v_is_correct boolean;
  v_points integer;
  v_total_score integer;
  v_answered_count integer;
  v_inserted boolean := false;
  v_rows integer;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if v_selected not in ('A','B','C','D') then
    raise exception 'الخيار المحدد غير صالح';
  end if;

  select challenge_date into v_date
  from public.daily_challenges where id = p_challenge_id;

  if not found or v_date <> current_date then
    raise exception 'هذا التحدي غير متاح اليوم';
  end if;

  select correct_option, coalesce(explanation, '')
    into v_correct, v_explanation
  from public.daily_challenge_keys
  where challenge_id = p_challenge_id;

  if not found then
    raise exception 'إجابة التحدي غير مهيأة';
  end if;

  v_is_correct := (v_selected = v_correct);
  v_points := case when v_is_correct then 20 else 0 end;

  insert into public.challenge_answers
    (user_id, challenge_id, selected_option, points_awarded)
  values (v_user_id, p_challenge_id, v_selected, v_points)
  on conflict (user_id, challenge_id) do nothing;

  get diagnostics v_rows = row_count;
  v_inserted := (v_rows = 1);
  if not v_inserted then
    -- The unique constraint prevents a second attempt; return the saved result.
    select points_awarded, selected_option
      into v_points, v_selected
    from public.challenge_answers
    where user_id = v_user_id and challenge_id = p_challenge_id;
    v_is_correct := (v_selected = v_correct);
  end if;

  select
    coalesce((select sum(points_awarded) from public.question_attempts where user_id = v_user_id), 0)
    + coalesce((select sum(points_awarded) from public.challenge_answers where user_id = v_user_id), 0),
    (select count(*) from public.question_attempts where user_id = v_user_id)
    + (select count(*) from public.challenge_answers where user_id = v_user_id)
  into v_total_score, v_answered_count;

  return jsonb_build_object(
    'already_answered', not v_inserted,
    'is_correct', v_is_correct,
    'correct_option', v_correct,
    'explanation', v_explanation,
    'points_awarded', v_points,
    'total_score', v_total_score,
    'answered_count', v_answered_count
  );
end;
$$;

-- Include daily bonus points in the player's total score.
create or replace function public.get_quiz_stats()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_total_score integer;
  v_answered_count integer;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  select
    coalesce((select sum(points_awarded) from public.question_attempts where user_id = v_user_id), 0)
      + coalesce((select sum(points_awarded) from public.challenge_answers where user_id = v_user_id), 0),
    (select count(*) from public.question_attempts where user_id = v_user_id)
      + (select count(*) from public.challenge_answers where user_id = v_user_id)
  into v_total_score, v_answered_count;

  return jsonb_build_object('total_score', v_total_score, 'answered_count', v_answered_count);
end;
$$;

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
  with all_scores as (
    select user_id, points_awarded from public.question_attempts
    union all
    select user_id, points_awarded from public.challenge_answers
  ),
  totals as (
    select user_id, coalesce(sum(points_awarded), 0)::bigint as score,
           count(*)::bigint as answered
    from all_scores group by user_id
  ),
  ranked as (
    select t.user_id, t.score, t.answered,
           row_number() over (order by t.score desc, t.answered desc, t.user_id) as place
    from totals t
  )
  select r.place,
         coalesce(nullif(left(p.username, 32), ''), 'لاعب')::text,
         r.score, r.answered, (r.user_id = v_user_id)
  from ranked r
  left join public.profiles p on p.id = r.user_id
  order by r.place
  limit 20;
end;
$$;

revoke all on function public.get_daily_challenge() from public, anon;
revoke all on function public.submit_daily_challenge_answer(uuid, text) from public, anon;
revoke all on function public.get_quiz_stats() from public, anon;
revoke all on function public.get_quiz_leaderboard() from public, anon;

grant execute on function public.get_daily_challenge() to authenticated;
grant execute on function public.submit_daily_challenge_answer(uuid, text) to authenticated;
grant execute on function public.get_quiz_stats() to authenticated;
grant execute on function public.get_quiz_leaderboard() to authenticated;
