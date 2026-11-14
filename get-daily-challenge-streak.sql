-- Daily challenge participation streak RPC.
-- A day counts when the player submits the daily challenge, regardless of correctness.
-- Dates follow PostgreSQL current_date, matching get_daily_challenge() and answer submission.

CREATE OR REPLACE FUNCTION public.get_daily_challenge_streak()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_today date := current_date;
  v_last_date date;
  v_current_streak integer := 0;
  v_best_streak integer := 0;
  v_participated_today boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.challenge_answers a
    JOIN public.daily_challenges d ON d.id = a.challenge_id
    WHERE a.user_id = v_user_id AND d.challenge_date = v_today
  ) INTO v_participated_today;

  SELECT max(d.challenge_date)
  INTO v_last_date
  FROM public.challenge_answers a
  JOIN public.daily_challenges d ON d.id = a.challenge_id
  WHERE a.user_id = v_user_id AND d.challenge_date <= v_today;

  WITH days AS (
    SELECT DISTINCT d.challenge_date
    FROM public.challenge_answers a
    JOIN public.daily_challenges d ON d.id = a.challenge_id
    WHERE a.user_id = v_user_id AND d.challenge_date <= v_today
  ),
  grouped AS (
    SELECT challenge_date,
           challenge_date - row_number() OVER (ORDER BY challenge_date)::integer AS streak_group
    FROM days
  )
  SELECT coalesce(max(streak_length), 0)
  INTO v_best_streak
  FROM (
    SELECT count(*)::integer AS streak_length
    FROM grouped
    GROUP BY streak_group
  ) streaks;

  IF v_last_date IS NOT NULL AND v_last_date >= v_today - 1 THEN
    WITH days AS (
      SELECT DISTINCT d.challenge_date
      FROM public.challenge_answers a
      JOIN public.daily_challenges d ON d.id = a.challenge_id
      WHERE a.user_id = v_user_id AND d.challenge_date <= v_today
    ),
    grouped AS (
      SELECT challenge_date,
             challenge_date - row_number() OVER (ORDER BY challenge_date)::integer AS streak_group
      FROM days
    ),
    current_group AS (
      SELECT streak_group FROM grouped WHERE challenge_date = v_last_date
    )
    SELECT count(*)::integer
    INTO v_current_streak
    FROM grouped
    WHERE streak_group = (SELECT streak_group FROM current_group);
  END IF;

  RETURN jsonb_build_object(
    'current_streak', v_current_streak,
    'best_streak', v_best_streak,
    'participated_today', v_participated_today,
    'last_participation_date', v_last_date,
    'today', v_today
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_daily_challenge_streak() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_daily_challenge_streak() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_daily_challenge_streak() TO authenticated;
