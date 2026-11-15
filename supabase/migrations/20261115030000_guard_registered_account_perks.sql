-- Restrict registered-account perks to permanent Supabase users.
-- Anonymous users use the authenticated Postgres role, so each SECURITY DEFINER
-- RPC must inspect the JWT is_anonymous claim explicitly.

CREATE OR REPLACE FUNCTION public.get_quiz_leaderboard()
RETURNS TABLE(rank_position bigint, username text, total_score bigint, answered_count bigint, is_me boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_is_anonymous boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
BEGIN
  IF v_user_id IS NULL OR v_is_anonymous THEN
    RAISE EXCEPTION 'لوحة المتصدرين متاحة للحسابات المسجّلة فقط';
  END IF;

  RETURN QUERY
  WITH all_scores AS (
    SELECT user_id, points_awarded FROM public.question_attempts
    UNION ALL
    SELECT user_id, points_awarded FROM public.challenge_answers
  ),
  totals AS (
    SELECT user_id,
      coalesce(sum(points_awarded), 0)::bigint AS score,
      count(*)::bigint AS answered
    FROM all_scores
    GROUP BY user_id
  ),
  ranked AS (
    SELECT t.user_id, t.score, t.answered,
      row_number() OVER (
        ORDER BY t.score DESC, t.answered DESC, t.user_id
      ) AS place
    FROM totals t
  )
  SELECT r.place,
    coalesce(nullif(left(p.username, 32), ''), 'لاعب')::text,
    r.score,
    r.answered,
    (r.user_id = v_user_id)
  FROM ranked r
  LEFT JOIN public.profiles p ON p.id = r.user_id
  ORDER BY r.place
  LIMIT 20;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_daily_challenge_streak()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_is_anonymous boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
  v_today date := current_date;
  v_last_date date;
  v_current_streak integer := 0;
  v_best_streak integer := 0;
  v_total_days integer := 0;
  v_participated_today boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
  END IF;
  IF v_is_anonymous THEN
    RAISE EXCEPTION 'الإنجازات اليومية متاحة للحسابات المسجّلة فقط';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.challenge_answers a
    JOIN public.daily_challenges d ON d.id=a.challenge_id
    WHERE a.user_id=v_user_id AND d.challenge_date=v_today
  ) INTO v_participated_today;

  SELECT max(d.challenge_date), count(DISTINCT d.challenge_date)::integer
  INTO v_last_date, v_total_days
  FROM public.challenge_answers a
  JOIN public.daily_challenges d ON d.id=a.challenge_id
  WHERE a.user_id=v_user_id AND d.challenge_date<=v_today;

  WITH days AS (
    SELECT DISTINCT d.challenge_date
    FROM public.challenge_answers a
    JOIN public.daily_challenges d ON d.id=a.challenge_id
    WHERE a.user_id=v_user_id AND d.challenge_date<=v_today
  ), grouped AS (
    SELECT challenge_date,
      challenge_date-row_number() OVER(ORDER BY challenge_date)::integer AS streak_group
    FROM days
  )
  SELECT coalesce(max(streak_length),0) INTO v_best_streak
  FROM (
    SELECT count(*)::integer AS streak_length
    FROM grouped GROUP BY streak_group
  ) streaks;

  IF v_last_date IS NOT NULL AND v_last_date>=v_today-1 THEN
    WITH days AS (
      SELECT DISTINCT d.challenge_date
      FROM public.challenge_answers a
      JOIN public.daily_challenges d ON d.id=a.challenge_id
      WHERE a.user_id=v_user_id AND d.challenge_date<=v_today
    ), grouped AS (
      SELECT challenge_date,
        challenge_date-row_number() OVER(ORDER BY challenge_date)::integer AS streak_group
      FROM days
    ), current_group AS (
      SELECT streak_group FROM grouped WHERE challenge_date=v_last_date
    )
    SELECT count(*)::integer INTO v_current_streak
    FROM grouped WHERE streak_group=(SELECT streak_group FROM current_group);
  END IF;

  RETURN jsonb_build_object(
    'current_streak',v_current_streak,
    'best_streak',v_best_streak,
    'total_participation_days',v_total_days,
    'participated_today',v_participated_today,
    'last_participation_date',v_last_date,
    'today',v_today
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_daily_challenge_answer(
  p_challenge_id uuid,
  p_selected_option text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_is_anonymous boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
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
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
  END IF;
  IF v_is_anonymous THEN
    RAISE EXCEPTION 'تحدّي اليوم متاح للحسابات المسجّلة فقط';
  END IF;
  IF v_selected NOT IN ('A','B','C','D') THEN
    RAISE EXCEPTION 'الخيار المحدد غير صالح';
  END IF;

  SELECT challenge_date INTO v_date
  FROM public.daily_challenges WHERE id = p_challenge_id;

  IF NOT FOUND OR v_date <> current_date THEN
    RAISE EXCEPTION 'هذا التحدي غير متاح اليوم';
  END IF;

  SELECT correct_option, coalesce(explanation, '')
  INTO v_correct, v_explanation
  FROM public.daily_challenge_keys
  WHERE challenge_id = p_challenge_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'إجابة التحدي غير مهيأة';
  END IF;

  v_is_correct := (v_selected = v_correct);
  v_points := CASE WHEN v_is_correct THEN 20 ELSE 0 END;

  INSERT INTO public.challenge_answers
    (user_id, challenge_id, selected_option, points_awarded)
  VALUES (v_user_id, p_challenge_id, v_selected, v_points)
  ON CONFLICT (user_id, challenge_id) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_inserted := (v_rows = 1);

  IF NOT v_inserted THEN
    SELECT points_awarded, selected_option
    INTO v_points, v_selected
    FROM public.challenge_answers
    WHERE user_id = v_user_id AND challenge_id = p_challenge_id;
    v_is_correct := (v_selected = v_correct);
  END IF;

  SELECT
    coalesce((SELECT sum(points_awarded) FROM public.question_attempts WHERE user_id = v_user_id), 0)
      + coalesce((SELECT sum(points_awarded) FROM public.challenge_answers WHERE user_id = v_user_id), 0),
    (SELECT count(*) FROM public.question_attempts WHERE user_id = v_user_id)
      + (SELECT count(*) FROM public.challenge_answers WHERE user_id = v_user_id)
  INTO v_total_score, v_answered_count;

  RETURN jsonb_build_object(
    'already_answered', NOT v_inserted,
    'is_correct', v_is_correct,
    'correct_option', v_correct,
    'explanation', v_explanation,
    'points_awarded', v_points,
    'total_score', v_total_score,
    'answered_count', v_answered_count
  );
END;
$function$;
