-- 남위례 햇살집 · 서버 설정 SQL (Supabase → SQL Editor에 통째로 붙여넣고 Run)
-- 여러 번 실행해도 안전합니다.

-- 1) 관리자
create table if not exists stay_admins (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz default now()
);
alter table stay_admins enable row level security;

create or replace function stay_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from stay_admins where user_id = auth.uid())
$$;

-- 처음 로그인한 한 사람만 관리자가 됩니다
create or replace function stay_claim_admin() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists (select 1 from stay_admins) then
    return exists (select 1 from stay_admins where user_id = auth.uid());
  end if;
  insert into stay_admins (user_id) values (auth.uid());
  return true;
end $$;

-- 2) 공개 내용 (소개, 공지, 사진 등) — 누구나 읽기, 관리자만 수정
create table if not exists stay_content (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);
insert into stay_content (id) values (1) on conflict do nothing;
alter table stay_content enable row level security;
drop policy if exists "stay content read" on stay_content;
create policy "stay content read" on stay_content for select using (true);
drop policy if exists "stay content write" on stay_content;
create policy "stay content write" on stay_content for update using (stay_is_admin()) with check (stay_is_admin());

-- 3) 예약 — 개인정보라서 관리자만 볼 수 있음. 날짜 겹침은 서버가 막음
create table if not exists stay_bookings (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  phone text not null default '',
  kakao text not null default '',
  guests int not null default 1,
  check_in date not null,
  check_out date not null,
  message text not null default '',
  status text not null default 'pending'
    check (status in ('pending','confirmed','declined','cancelled','blocked')),
  admin_note text not null default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  check (check_out > check_in)
);
-- 확정·호스트 사용 날짜만 서로 겹칠 수 없음 (신청 중인 날짜는 대기 신청 가능)
alter table stay_bookings drop constraint if exists stay_no_overlap;
alter table stay_bookings add constraint stay_no_overlap exclude using gist (daterange(check_in, check_out) with &&)
  where (status in ('confirmed','blocked'));
alter table stay_bookings add column if not exists checks jsonb not null default '{}'::jsonb;
alter table stay_bookings add column if not exists checks_at timestamptz;
-- 앞 순위가 확정된 뒤 대기 손님의 선택 ('' = 아직, 'wait' = 계속 기다리기)
alter table stay_bookings add column if not exists wait_choice text not null default '';
alter table stay_bookings enable row level security;
drop policy if exists "stay bookings admin" on stay_bookings;
create policy "stay bookings admin" on stay_bookings for all using (stay_is_admin()) with check (stay_is_admin());

-- 4) 비밀 정보 (출입 비번, 와이파이, 호수) — 관리자만
create table if not exists stay_secret (
  id int primary key default 1 check (id = 1),
  door_code text not null default '',
  wifi_name text not null default '',
  wifi_pw text not null default '',
  private_guide text not null default '',
  show_in_app boolean not null default false,
  updated_at timestamptz default now()
);
insert into stay_secret (id) values (1) on conflict do nothing;
alter table stay_secret add column if not exists building_code text not null default '';
alter table stay_secret enable row level security;
drop policy if exists "stay secret admin" on stay_secret;
create policy "stay secret admin" on stay_secret for all using (stay_is_admin()) with check (stay_is_admin());

-- 5) 손님용 기능 (이름·연락처는 절대 내보내지 않음)
create or replace function stay_busy_dates()
returns table (check_in date, check_out date, status text)
language sql stable security definer set search_path = public as $$
  select b.check_in, b.check_out,
         case when b.status = 'pending' then 'pending' else 'booked' end
  from stay_bookings b
  where b.status in ('pending','confirmed','blocked')
    and b.check_out >= (now() at time zone 'Asia/Seoul')::date - 1
$$;

create or replace function stay_request(
  p_name text, p_phone text, p_kakao text, p_guests int,
  p_in date, p_out date, p_message text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_max int; v_maxn int; v_minn int; v_digits text; v_code text := '';
  v_abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int; v_q int;
begin
  select coalesce((data->>'maxGuests')::int, 2), coalesce((data->>'maxNights')::int, 90),
         coalesce((data->>'minNights')::int, 1)
    into v_max, v_maxn, v_minn from stay_content where id = 1;
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(trim(coalesce(p_name, ''))) < 1 or length(p_name) > 40 then raise exception 'bad_name'; end if;
  if length(v_digits) < 9 or length(v_digits) > 13 then raise exception 'bad_phone'; end if;
  if p_in < v_today or p_out <= p_in or p_in > v_today + 400
     or (p_out - p_in) > v_maxn or (p_out - p_in) < v_minn then raise exception 'bad_dates'; end if;
  if p_guests < 1 or p_guests > v_max then raise exception 'bad_guests'; end if;
  if (select count(*) from stay_bookings where phone = v_digits and status = 'pending') >= 3 then
    raise exception 'too_many';
  end if;
  if exists (select 1 from stay_bookings where status in ('confirmed','blocked')
             and daterange(check_in, check_out) && daterange(p_in, p_out)) then
    raise exception 'overlap';
  end if;
  select 1 + count(*) into v_q from stay_bookings
   where status = 'pending' and daterange(check_in, check_out) && daterange(p_in, p_out);
  for i in 1..8 loop
    v_code := v_code || substr(v_abc, 1 + floor(random() * length(v_abc))::int, 1);
  end loop;
  begin
    insert into stay_bookings (code, name, phone, kakao, guests, check_in, check_out, message)
    values (v_code, trim(p_name), v_digits, left(coalesce(p_kakao, ''), 40), p_guests,
            p_in, p_out, left(coalesce(p_message, ''), 500));
  exception when exclusion_violation then
    raise exception 'overlap';
  end;
  return json_build_object('code', v_code, 'check_in', p_in, 'check_out', p_out, 'status', 'pending', 'queue', v_q);
end $$;

-- 예약코드 + 휴대폰 뒤 4자리로 조회. '앱에서 보여주기'가 켜져 있으면 확정 + 입실 전날~퇴실 날에만 비번 공개
create or replace function stay_lookup(p_code text, p_last4 text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  b stay_bookings%rowtype; s stay_secret%rowtype; r jsonb;
begin
  select * into b from stay_bookings
   where code = upper(trim(p_code)) and right(phone, 4) = trim(p_last4) and status <> 'blocked';
  if not found then return null; end if;
  r := jsonb_build_object('code', b.code, 'name', b.name, 'guests', b.guests,
        'check_in', b.check_in, 'check_out', b.check_out, 'status', b.status, 'checks', b.checks);
  if b.status = 'pending' then
    r := r || jsonb_build_object('queue', 1 + (select count(*) from stay_bookings x
      where x.status = 'pending' and x.id <> b.id and x.created_at < b.created_at
        and daterange(x.check_in, x.check_out) && daterange(b.check_in, b.check_out)),
      'ahead_confirmed', exists (select 1 from stay_bookings x
        where x.status in ('confirmed','blocked') and daterange(x.check_in, x.check_out) && daterange(b.check_in, b.check_out)),
      'wait_choice', b.wait_choice);
  end if;
  if b.status = 'confirmed' then
    select * into s from stay_secret where id = 1;
    if not coalesce(s.show_in_app, false) then
      r := r || jsonb_build_object('reveal_by_host', true);
    elsif v_today between b.check_in - 1 and b.check_out then
      r := r || jsonb_build_object('door_code', s.door_code, 'building_code', s.building_code, 'wifi_name', s.wifi_name,
             'wifi_pw', s.wifi_pw, 'private_guide', s.private_guide);
    end if;
  end if;
  return r::json;
end $$;

create or replace function stay_cancel(p_code text, p_last4 text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Asia/Seoul')::date; n int;
begin
  update stay_bookings set status = 'cancelled', updated_at = now()
   where code = upper(trim(p_code)) and right(phone, 4) = trim(p_last4)
     and status in ('pending','confirmed') and check_in > v_today;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- 앞 순위 확정 후 '계속 기다리기' 선택 (신청 중인 본인 예약만)
create or replace function stay_choose_wait(p_code text, p_last4 text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update stay_bookings set wait_choice = 'wait', updated_at = now()
   where code = upper(trim(p_code)) and right(phone, 4) = trim(p_last4) and status = 'pending';
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- 퇴실 체크리스트 저장 (확정된 본인 예약만)
create or replace function stay_save_checks(p_code text, p_last4 text, p_checks jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if pg_column_size(p_checks) > 2000 then return false; end if;
  update stay_bookings set checks = coalesce(p_checks, '{}'::jsonb), checks_at = now()
   where code = upper(trim(p_code)) and right(phone, 4) = trim(p_last4) and status = 'confirmed';
  get diagnostics n = row_count;
  return n > 0;
end $$;

grant execute on function stay_save_checks(text,text,jsonb) to anon, authenticated;
grant execute on function stay_choose_wait(text,text) to anon, authenticated;
grant execute on function stay_busy_dates() to anon, authenticated;
grant execute on function stay_request(text,text,text,int,date,date,text) to anon, authenticated;
grant execute on function stay_lookup(text,text) to anon, authenticated;
grant execute on function stay_cancel(text,text) to anon, authenticated;
grant execute on function stay_claim_admin() to authenticated;
grant execute on function stay_is_admin() to anon, authenticated;

-- 6) 사진 저장소 (누구나 보기, 관리자만 올리기/지우기)
insert into storage.buckets (id, name, public) values ('stay-photos', 'stay-photos', true)
on conflict (id) do nothing;
drop policy if exists "stay photos insert" on storage.objects;
create policy "stay photos insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'stay-photos' and public.stay_is_admin());
drop policy if exists "stay photos update" on storage.objects;
create policy "stay photos update" on storage.objects for update to authenticated
  using (bucket_id = 'stay-photos' and public.stay_is_admin());
drop policy if exists "stay photos delete" on storage.objects;
create policy "stay photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'stay-photos' and public.stay_is_admin());

-- 7) 자동 백업 — 매일 새벽 3시(한국 시간)에 내용과 예약을 복사해 30일 보관 (비밀번호 정보는 제외)
create table if not exists stay_backups (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  data jsonb not null
);
alter table stay_backups enable row level security;
drop policy if exists "stay backups admin" on stay_backups;
create policy "stay backups admin" on stay_backups for select using (stay_is_admin());

create or replace function stay_backup_now() returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if auth.uid() is not null and not stay_is_admin() then raise exception 'not_admin'; end if;
  insert into stay_backups (data)
  select jsonb_build_object(
    'content', (select data from stay_content where id = 1),
    'bookings', coalesce((select jsonb_agg(to_jsonb(b) order by b.check_in) from stay_bookings b), '[]'::jsonb))
  returning id into v_id;
  delete from stay_backups where created_at < now() - interval '30 days';
  return v_id;
end $$;
revoke execute on function stay_backup_now() from public, anon;
grant execute on function stay_backup_now() to authenticated;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('stay-daily-backup') where exists (select 1 from cron.job where jobname = 'stay-daily-backup');
  perform cron.schedule('stay-daily-backup', '0 18 * * *', 'select public.stay_backup_now()');
exception when others then
  raise notice '자동 백업 예약을 건너뜀 (pg_cron 사용 불가). 앱의 "지금 백업" 버튼은 그대로 쓸 수 있어요.';
end $$;

-- 8) 호스트 여러 명 — 호스트가 다른 사람의 이메일을 호스트로 추가/삭제
create or replace function stay_add_admin(p_email text) returns boolean
language plpgsql security definer set search_path = public, auth as $$
declare v uuid;
begin
  if not stay_is_admin() then raise exception 'not_admin'; end if;
  select id into v from auth.users where lower(email) = lower(trim(p_email));
  if v is null then raise exception 'no_user'; end if;
  insert into stay_admins (user_id) values (v) on conflict do nothing;
  return true;
end $$;

create or replace function stay_list_admins() returns table (email text, me boolean)
language sql stable security definer set search_path = public, auth as $$
  select u.email::text, u.id = auth.uid()
  from stay_admins a join auth.users u on u.id = a.user_id
  where stay_is_admin()
  order by a.created_at
$$;

create or replace function stay_remove_admin(p_email text) returns boolean
language plpgsql security definer set search_path = public, auth as $$
declare v uuid;
begin
  if not stay_is_admin() then raise exception 'not_admin'; end if;
  select id into v from auth.users where lower(email) = lower(trim(p_email));
  if v is null or v = auth.uid() then raise exception 'cannot_remove'; end if;
  delete from stay_admins where user_id = v;
  return true;
end $$;

revoke execute on function stay_add_admin(text) from public, anon;
revoke execute on function stay_list_admins() from public, anon;
revoke execute on function stay_remove_admin(text) from public, anon;
grant execute on function stay_add_admin(text) to authenticated;
grant execute on function stay_list_admins() to authenticated;
grant execute on function stay_remove_admin(text) to authenticated;
