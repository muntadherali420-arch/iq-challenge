-- Invite-code player challenges. Scores and answer validation stay server-side.
create table if not exists public.duel_rooms (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique check (invite_code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  host_id uuid not null references auth.users(id) on delete cascade,
  guest_id uuid references auth.users(id) on delete cascade,
  status text not null default 'waiting' check (status in ('waiting','active','completed','cancelled')),
  question_ids uuid[] not null check (cardinality(question_ids) = 5),
  host_score integer not null default 0 check (host_score >= 0),
  guest_score integer not null default 0 check (guest_score >= 0),
  winner_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  completed_at timestamptz
);
create index if not exists duel_rooms_host_created_idx on public.duel_rooms(host_id, created_at desc);
create index if not exists duel_rooms_guest_created_idx on public.duel_rooms(guest_id, created_at desc);

create table if not exists public.duel_answers (
  room_id uuid not null references public.duel_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_index integer not null check (question_index between 0 and 4),
  selected_option text not null check (selected_option in ('A','B','C','D')),
  is_correct boolean not null,
  points_awarded integer not null default 0 check (points_awarded in (0,10)),
  answered_at timestamptz not null default now(),
  primary key (room_id, user_id, question_index)
);
create index if not exists duel_answers_user_room_idx on public.duel_answers(user_id, room_id);
alter table public.duel_rooms enable row level security;
alter table public.duel_answers enable row level security;
revoke all on public.duel_rooms, public.duel_answers from anon, authenticated;

create or replace function public.get_duel_room(p_room_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.duel_rooms%rowtype;
  v_host_name text;
  v_guest_name text;
  v_winner_name text;
  v_questions jsonb;
  v_my_answered jsonb;
  v_host_answered integer;
  v_guest_answered integer;
  v_is_host boolean;
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول للمشاركة في المواجهات'; end if;
  if coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'المواجهات متاحة للحسابات المسجّلة فقط';
  end if;
  select * into v_room from public.duel_rooms where id = p_room_id;
  if not found then raise exception 'الغرفة غير موجودة'; end if;
  if v_uid <> v_room.host_id and v_uid is distinct from v_room.guest_id then
    raise exception 'ليس لديك إذن لعرض هذه الغرفة';
  end if;
  if v_room.status in ('waiting','active') and v_room.expires_at <= now() then
    update public.duel_rooms set status = 'cancelled' where id = v_room.id;
    select * into v_room from public.duel_rooms where id = p_room_id;
  end if;
  v_is_host := v_uid = v_room.host_id;
  select coalesce(nullif(btrim(username),''), 'لاعب') into v_host_name
    from public.profiles where id = v_room.host_id;
  select coalesce(nullif(btrim(username),''), 'لاعب') into v_guest_name
    from public.profiles where id = v_room.guest_id;
  select coalesce(nullif(btrim(username),''), 'لاعب') into v_winner_name
    from public.profiles where id = v_room.winner_id;
  select count(*)::integer into v_host_answered
    from public.duel_answers where room_id = v_room.id and user_id = v_room.host_id;
  if v_room.guest_id is not null then
    select count(*)::integer into v_guest_answered
      from public.duel_answers where room_id = v_room.id and user_id = v_room.guest_id;
  else v_guest_answered := 0; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'question_text', q.question_text, 'option_a', q.option_a,
      'option_b', q.option_b, 'option_c', q.option_c, 'option_d', q.option_d
    ) order by selected.ordinality), '[]'::jsonb)
    into v_questions
    from unnest(v_room.question_ids) with ordinality as selected(question_id, ordinality)
    join public.questions q on q.id = selected.question_id;
  select coalesce(jsonb_agg(question_index order by question_index), '[]'::jsonb)
    into v_my_answered
    from public.duel_answers where room_id = v_room.id and user_id = v_uid;
  return jsonb_build_object(
    'room_id', v_room.id, 'invite_code', v_room.invite_code, 'status', v_room.status,
    'is_host', v_is_host, 'host_name', coalesce(v_host_name, 'اللاعب الأول'),
    'guest_name', coalesce(v_guest_name, 'بانتظار صديقك'),
    'host_score', v_room.host_score, 'guest_score', v_room.guest_score,
    'host_answered', v_host_answered, 'guest_answered', v_guest_answered,
    'my_answered', v_my_answered, 'questions', v_questions,
    'winner_name', v_winner_name, 'winner_is_me', v_room.winner_id = v_uid,
    'is_tie', v_room.status = 'completed' and v_room.winner_id is null
  );
end;
$$;

create or replace function public.create_duel_room()
returns jsonb language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_question_ids uuid[];
  v_code text;
  v_room_id uuid;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'أنشئ حساباً مسجّلاً لبدء مواجهة الأصدقاء';
  end if;
  select array_agg(id) into v_question_ids from (
    select id from public.questions
    where is_active = true and category <> 'ألغاز وأحجيات مخادعة'
    order by random() limit 5
  ) as picked;
  if coalesce(cardinality(v_question_ids), 0) <> 5 then
    raise exception 'لا توجد أسئلة كافية لإنشاء المواجهة حالياً';
  end if;
  loop
    select string_agg(substr(v_alphabet, floor(random() * length(v_alphabet))::integer + 1, 1), '')
      into v_code from generate_series(1, 8);
    exit when not exists (select 1 from public.duel_rooms where invite_code = v_code);
  end loop;
  insert into public.duel_rooms(invite_code, host_id, question_ids)
    values (v_code, v_uid, v_question_ids) returning id into v_room_id;
  return public.get_duel_room(v_room_id);
end;
$$;

create or replace function public.join_duel_room(p_invite_code text)
returns jsonb language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.duel_rooms%rowtype;
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'أنشئ حساباً مسجّلاً للانضمام إلى المواجهة';
  end if;
  select * into v_room from public.duel_rooms
    where invite_code = upper(btrim(p_invite_code)) for update;
  if not found then raise exception 'رمز الدعوة غير صحيح'; end if;
  if v_room.host_id = v_uid then raise exception 'لا يمكنك الانضمام إلى غرفتك بحساب اللاعب نفسه'; end if;
  if v_room.status = 'waiting' and v_room.expires_at <= now() then
    update public.duel_rooms set status = 'cancelled' where id = v_room.id;
    raise exception 'انتهت صلاحية رمز الدعوة';
  end if;
  if v_room.status = 'active' and v_room.guest_id = v_uid then
    return public.get_duel_room(v_room.id);
  end if;
  if v_room.status <> 'waiting' then raise exception 'هذه الغرفة لم تعد متاحة'; end if;
  update public.duel_rooms set guest_id = v_uid, status = 'active',
    expires_at = now() + interval '15 minutes' where id = v_room.id;
  return public.get_duel_room(v_room.id);
end;
$$;

create or replace function public.submit_duel_answer(
  p_room_id uuid, p_question_index integer, p_selected_option text
)
returns jsonb language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.duel_rooms%rowtype;
  v_correct_option text;
  v_is_correct boolean;
  v_points integer;
  v_existing public.duel_answers%rowtype;
  v_answered_count integer;
  v_host_count integer;
  v_guest_count integer;
  v_host_score integer;
  v_guest_score integer;
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'المواجهات متاحة للحسابات المسجّلة فقط';
  end if;
  if p_question_index is null or p_question_index not between 0 and 4 then
    raise exception 'رقم السؤال غير صحيح';
  end if;
  if upper(p_selected_option) not in ('A','B','C','D') then
    raise exception 'الخيار المحدد غير صحيح';
  end if;
  select * into v_room from public.duel_rooms where id = p_room_id for update;
  if not found then raise exception 'الغرفة غير موجودة'; end if;
  if v_uid <> v_room.host_id and v_uid is distinct from v_room.guest_id then
    raise exception 'ليس لديك إذن للإجابة في هذه الغرفة';
  end if;
  select * into v_existing from public.duel_answers
    where room_id = p_room_id and user_id = v_uid and question_index = p_question_index;
  if found then
    return jsonb_build_object('is_correct',v_existing.is_correct,
      'points_awarded',v_existing.points_awarded,'already_answered',true);
  end if;
  if v_room.status <> 'active' then raise exception 'المواجهة ليست نشطة حالياً'; end if;
  if v_room.expires_at <= now() then
    update public.duel_rooms set status = 'cancelled' where id = v_room.id;
    raise exception 'انتهى وقت المواجهة';
  end if;
  select count(*)::integer into v_answered_count from public.duel_answers
    where room_id = p_room_id and user_id = v_uid;
  if p_question_index <> v_answered_count then raise exception 'أجب عن الأسئلة بالترتيب'; end if;
  select correct_option into v_correct_option
    from public.questions where id = v_room.question_ids[p_question_index + 1];
  if v_correct_option is null then raise exception 'تعذّر التحقق من إجابة السؤال'; end if;
  v_is_correct := upper(p_selected_option) = v_correct_option;
  v_points := case when v_is_correct then 10 else 0 end;
  insert into public.duel_answers(room_id,user_id,question_index,selected_option,is_correct,points_awarded)
    values (p_room_id,v_uid,p_question_index,upper(p_selected_option),v_is_correct,v_points);
  if v_uid = v_room.host_id then
    update public.duel_rooms set host_score = host_score + v_points where id = p_room_id;
  else
    update public.duel_rooms set guest_score = guest_score + v_points where id = p_room_id;
  end if;
  select count(*)::integer into v_host_count from public.duel_answers
    where room_id = p_room_id and user_id = v_room.host_id;
  select count(*)::integer into v_guest_count from public.duel_answers
    where room_id = p_room_id and user_id = v_room.guest_id;
  select host_score,guest_score into v_host_score,v_guest_score
    from public.duel_rooms where id = p_room_id;
  if v_room.guest_id is not null and v_host_count = 5 and v_guest_count = 5 then
    update public.duel_rooms set status = 'completed',
      winner_id = case when v_host_score > v_guest_score then v_room.host_id
        when v_guest_score > v_host_score then v_room.guest_id else null end,
      completed_at = now() where id = p_room_id;
  end if;
  return jsonb_build_object('is_correct',v_is_correct,'points_awarded',v_points,
    'correct_option',v_correct_option,'already_answered',false);
end;
$$;

revoke all on function public.get_duel_room(uuid) from public, anon;
revoke all on function public.create_duel_room() from public, anon;
revoke all on function public.join_duel_room(text) from public, anon;
revoke all on function public.submit_duel_answer(uuid, integer, text) from public, anon;
grant execute on function public.get_duel_room(uuid) to authenticated;
grant execute on function public.create_duel_room() to authenticated;
grant execute on function public.join_duel_room(text) to authenticated;
grant execute on function public.submit_duel_answer(uuid, integer, text) to authenticated;
comment on table public.duel_rooms is 'Private invite-code quiz rooms; access only through membership-checked RPCs.';
comment on table public.duel_answers is 'Server-validated answers and scores for invite-code quiz duels.';
