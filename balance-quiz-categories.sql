-- Balance each standard quiz round across question categories.
-- Prefer five different categories; if fewer than five categories remain for
-- the selected difficulty, fill the remaining slots from the eligible pool.
create or replace function public.get_quiz_questions_by_difficulty(
  p_difficulty text default 'all'
)
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
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  if p_difficulty is null
     or p_difficulty not in ('all','easy','medium','hard','expert','genius') then
    raise exception 'مستوى الصعوبة غير صالح';
  end if;

  return query
  with eligible as materialized (
    select q.id, q.question_text, q.option_a, q.option_b,
           q.option_c, q.option_d, q.category, q.difficulty
    from public.questions q
    where q.is_active = true
      and q.category <> 'ألغاز وأحجيات مخادعة'
      and (p_difficulty = 'all' or q.difficulty = p_difficulty)
      and not exists (
        select 1
        from public.question_attempts a
        where a.user_id = v_user_id
          and a.question_id = q.id
      )
  ),
  one_per_category as materialized (
    select distinct on (e.category)
      e.id, e.question_text, e.option_a, e.option_b,
      e.option_c, e.option_d, e.category, e.difficulty
    from eligible e
    order by e.category, random()
  ),
  diverse as materialized (
    select *
    from one_per_category
    order by random()
    limit 5
  ),
  fill_remaining as (
    select e.*
    from eligible e
    where not exists (select 1 from diverse d where d.id = e.id)
    order by random()
    limit greatest(0, 5 - (select count(*) from diverse))
  )
  select s.id, s.question_text, s.option_a, s.option_b,
         s.option_c, s.option_d, s.category, s.difficulty
  from (
    select * from diverse
    union all
    select * from fill_remaining
  ) s
  order by random()
  limit 5;
end;
$function$;

-- Preserve the existing authenticated-only RPC access.
revoke all on function public.get_quiz_questions_by_difficulty(text) from public, anon;
grant execute on function public.get_quiz_questions_by_difficulty(text) to authenticated;
