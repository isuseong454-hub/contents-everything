-- ══════════════════════════════════════════════════════════════
-- 컨텐츠의 모든것(cme) — 백엔드 1단계
--   ⚠️ 2026-08-18 수리: 앱 공장 템플릿이 «아이디어 폴더» 테이블명을 그대로 갖고 있어
--      컨모 전용(cme_users / cme_items)으로 바꾸고, 두 테이블 생성 구문을 앞에 붙였다.
--   안전: 전부 «있으면 넘어감(if not exists)» — 기존 데이터를 지우거나 바꾸지 않는다.
-- ══════════════════════════════════════════════════════════════

create table if not exists cme_users (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  pin           text not null,
  name          text,
  created_at    timestamptz default now(),
  expires_at    timestamptz,
  is_admin      boolean default false,
  note          text,
  must_set_pin  boolean default true,
  hash_ver      int default 0,
  fail_count    int default 0,
  locked_until  timestamptz
);

create table if not exists cme_items (
  id          uuid primary key default gen_random_uuid(),
  user_code   text not null,
  ws          text not null default 'benchmark',
  grp         text default '유형 미지정',
  type        text default 'idea',
  text        text,
  url         text,
  title       text,
  img_path    text,
  memo        text,
  tags        text[] default '{}',
  fav         boolean default false,
  uses        int default 0,
  views       text,
  created_at  timestamptz default now()
);

create index if not exists cme_items_user_idx on cme_items(user_code);
create index if not exists cme_items_ws_idx   on cme_items(user_code, ws);

-- ═══════════════════════════════════════════════════════════════
-- 아이디어 폴더 🔐 보안 1단계 (2026-07-26)
-- 막는 것: ①코드·비번 목록 통째 열람 ②비번 원문 저장 ③무제한 대입
--          ④외부인의 코드 생성/삭제  +  ⏳만료 3일 유예(서버 기준)
-- 실행법: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → RUN
-- ⚠️ 순서: 새 index.html을 먼저 배포한 뒤 이 SQL을 RUN 하세요.
--         (새 앱은 SQL 전/후 모두 동작, 옛 앱은 SQL 후 동작 불가)
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;   -- ⚠️ Supabase는 pgcrypto가 extensions 방에 설치됨

-- 1) 컬럼 추가 (실패 잠금 + 해시 버전)
alter table cme_users add column if not exists hash_ver    int default 0;
alter table cme_users add column if not exists fail_count  int default 0;
alter table cme_users add column if not exists locked_until timestamptz;

-- 2) 세션 테이블
create table if not exists cme_sessions(
  token      uuid primary key default gen_random_uuid(),
  code       text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days'
);

-- 3) 문 잠그기 — 테이블 직접 접근 전면 차단
alter table cme_users enable row level security;
alter table cme_items enable row level security;
alter table cme_sessions      enable row level security;
revoke all on table cme_users from anon, authenticated;
revoke all on table cme_items from anon, authenticated;
revoke all on table cme_sessions      from anon, authenticated;

-- 4) 소금 해시 (코드가 소금 — 같은 PIN이어도 사람마다 해시가 다름)
create or replace function cme_salt(p_code text, p_pin text) returns text
language sql immutable set search_path=public, extensions as
$$ select encode(digest(upper(trim(p_code))||':'||p_pin,'sha256'),'hex') $$;

-- 5) 내부: 비번 검증 + 실패 잠금(8회/5분) + 소금 승급. 상태 글자를 돌려준다(ok/no_code/locked/wrong)
-- ⚠️ 검증기는 예외를 던지지 않는다. fail_count 를 올린 뒤 raise 하면
--    부르는 쪽 begin…exception 이 그 증가분까지 되감아 «잠금이 영영 안 걸린다».
--    (2026-08-21에 실제로 새고 있던 자리) 다시 raise 로 바꾸지 말 것.
CREATE OR REPLACE FUNCTION public.cme_verify(p_code text, p_pin text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare u cme_users;
begin
  select * into u from cme_users where upper(code)=upper(trim(p_code));
  if u.code is null then return 'no_code'; end if;
  if u.locked_until is not null and u.locked_until>now() then return 'locked'; end if;
  if not ( u.pin = p_pin
        or u.pin = encode(digest(p_pin,'sha256'),'hex')
        or u.pin = cme_salt(u.code,p_pin) ) then
    update cme_users set fail_count=coalesce(fail_count,0)+1,
      locked_until=case when coalesce(fail_count,0)+1>=8 then now()+interval '5 minutes' else locked_until end
      where code=u.code;
    return 'wrong';
  end if;
  update cme_users set fail_count=0, locked_until=null,
    pin=cme_salt(u.code,p_pin), hash_ver=1 where code=u.code;
  return 'ok';
end $function$
;
drop function if exists cme_check_user(text,text);

-- 6) 로그인 → 세션 토큰 발급 (만료+3일 유예)
CREATE OR REPLACE FUNCTION public.cme_login(p_code text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare u cme_users; tok uuid; s text;
begin
  s := cme_verify(p_code,p_pin);
  if s <> 'ok' then return jsonb_build_object('ok',false,'msg',s); end if;
  select * into u from cme_users where upper(code)=upper(trim(p_code));
  if u.expires_at is not null and u.expires_at + interval '3 days' < now() then
    return jsonb_build_object('ok',false,'msg','expired');
  end if;
  delete from cme_sessions where expires_at<now();
  insert into cme_sessions(code) values(u.code) returning token into tok;
  return jsonb_build_object('ok',true,'token',tok,'name',coalesce(u.name,''),
    'expires_at',u.expires_at,'must_set_pin',coalesce(u.must_set_pin,false));
end $function$
;

-- 7) 세션 확인 (자동 로그인)
create or replace function cme_session(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s cme_sessions; u cme_users;
begin
  select * into s from cme_sessions
    where token=p_token and upper(code)=upper(trim(p_code)) and expires_at>now();
  if s.token is null then return jsonb_build_object('ok',false,'msg','session'); end if;
  select * into u from cme_users where code=s.code;
  if u.code is null then return jsonb_build_object('ok',false,'msg','no_code'); end if;
  if u.expires_at is not null and u.expires_at + interval '3 days' < now() then
    delete from cme_sessions where code=u.code;
    return jsonb_build_object('ok',false,'msg','expired');
  end if;
  return jsonb_build_object('ok',true,'name',coalesce(u.name,''),
    'expires_at',u.expires_at,'must_set_pin',coalesce(u.must_set_pin,false));
end $$;

-- 8) 내부: 세션 유효성 → 코드 반환 (데이터 함수용)
create or replace function cme_sess_ok(p_code text, p_token uuid) returns text
language plpgsql security definer set search_path=public as $$
declare s cme_sessions; u cme_users;
begin
  select * into s from cme_sessions
    where token=p_token and upper(code)=upper(trim(p_code)) and expires_at>now();
  if s.token is null then raise exception 'session'; end if;
  select * into u from cme_users where code=s.code;
  if u.expires_at is not null and u.expires_at + interval '3 days' < now() then
    raise exception 'expired';
  end if;
  return s.code;
end $$;

-- 9) 처음이신가요 — 코드 상태 확인 / 첫 비번 설정
create or replace function cme_first_check(p_code text) returns text
language plpgsql security definer set search_path=public as $$
declare u cme_users;
begin
  select * into u from cme_users where upper(code)=upper(trim(p_code));
  if u.code is null or coalesce(u.is_admin,false) then return 'no_code'; end if;
  if u.expires_at is not null and u.expires_at + interval '3 days' < now() then return 'expired'; end if;
  if not coalesce(u.must_set_pin,false) then return 'already_set'; end if;
  return 'ok';
end $$;

create or replace function cme_first(p_code text, p_pin text, p_nick text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare u cme_users; tok uuid;
begin
  select * into u from cme_users where upper(code)=upper(trim(p_code));
  if u.code is null or coalesce(u.is_admin,false) then return jsonb_build_object('ok',false,'msg','no_code'); end if;
  if u.expires_at is not null and u.expires_at + interval '3 days' < now() then return jsonb_build_object('ok',false,'msg','expired'); end if;
  if not coalesce(u.must_set_pin,false) then return jsonb_build_object('ok',false,'msg','already_set'); end if;
  update cme_users set pin=cme_salt(u.code,p_pin), hash_ver=1, must_set_pin=false,
    name=coalesce(nullif(trim(p_nick),''),name), fail_count=0, locked_until=null
    where code=u.code;
  insert into cme_sessions(code) values(u.code) returning token into tok;
  return jsonb_build_object('ok',true,'token',tok,'expires_at',u.expires_at,'name',coalesce(nullif(trim(p_nick),''),u.name,''));
end $$;

-- 10) 비번 변경 (임시비번 로그인 후 재설정 등 — 세션 필요)
create or replace function cme_set_pin(p_code text, p_token uuid, p_pin text, p_nick text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_code text; v_exp timestamptz; v_name text;
begin
  begin v_code:=cme_sess_ok(p_code,p_token);
  exception when others then return jsonb_build_object('ok',false,'msg',sqlerrm); end;
  update cme_users set pin=cme_salt(v_code,p_pin), hash_ver=1, must_set_pin=false,
    name=coalesce(nullif(trim(p_nick),''),name)
    where code=v_code returning expires_at, name into v_exp, v_name;
  return jsonb_build_object('ok',true,'expires_at',v_exp,'name',coalesce(v_name,''));
end $$;

-- 11) 데이터 — 세션 토큰으로만 (내 것만)
create or replace function cme_items_get(p_code text, p_token uuid) returns setof cme_items
language plpgsql security definer set search_path=public as $$
declare v_code text;
begin
  v_code:=cme_sess_ok(p_code,p_token);
  return query select * from cme_items where user_code=v_code order by created_at desc;
end $$;

create or replace function cme_items_upsert(p_code text, p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_code text;
begin
  begin v_code:=cme_sess_ok(p_code,p_token);
  exception when others then return jsonb_build_object('ok',false,'msg',sqlerrm); end;
  delete from cme_items
    where user_code=v_code and id::text in (select e->>'id' from jsonb_array_elements(p_rows) e);
  insert into cme_items
    select * from jsonb_populate_recordset(null::cme_items,
      (select coalesce(jsonb_agg(jsonb_set(e,'{user_code}',to_jsonb(v_code))),'[]'::jsonb)
         from jsonb_array_elements(p_rows) e));
  return jsonb_build_object('ok',true);
end $$;

create or replace function cme_items_del(p_code text, p_token uuid, p_ids text[]) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_code text;
begin
  begin v_code:=cme_sess_ok(p_code,p_token);
  exception when others then return jsonb_build_object('ok',false,'msg',sqlerrm); end;
  delete from cme_items where user_code=v_code and id::text = any(p_ids);
  return jsonb_build_object('ok',true);
end $$;

-- 12) 관리자 통로 (비번 검증+잠금 후 op 실행)
create or replace function cme_gen_code() returns text
language plpgsql volatile as $$
declare cs text:='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; s text:=''; i int;
begin
  for i in 1..6 loop s:=s||substr(cs, 1+floor(random()*length(cs))::int, 1); end loop;
  return s;
end $$;

CREATE OR REPLACE FUNCTION public.cme_admin(p_id text, p_pw text, p_op text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_st text; a cme_users; r jsonb; v_code text; v_months int; v_pin text; v_exp timestamptz; i int; v_name text;
begin
  select * into a from cme_users where upper(code)=upper(trim(p_id)) and coalesce(is_admin,false)=true;
  if a.code is null then return jsonb_build_object('ok',false,'msg','auth'); end if;
  v_st := cme_verify(a.code, p_pw);
  if v_st <> 'ok' then return jsonb_build_object('ok',false,'msg',v_st); end if;

  if p_op='ping' then
    r:=jsonb_build_object('ok',true);

  elsif p_op='list' then
    select jsonb_build_object('ok',true,'rows',
      coalesce(jsonb_agg((to_jsonb(t) - 'pin') order by t.created_at desc),'[]'::jsonb)) into r
    from (select * from cme_users where coalesce(is_admin,false)=false) t;

  elsif p_op='create' then
    v_months:=coalesce((p_args->>'months')::int,12);
    v_name:=nullif(trim(coalesce(p_args->>'name','')),'');
    for i in 1..8 loop
      v_code:=cme_gen_code();
      begin
        insert into cme_users(code,pin,name,expires_at,is_admin,must_set_pin,hash_ver)
        values(v_code, cme_salt(v_code, lpad((floor(random()*9000)+1000)::int::text,4,'0')), v_name,
               case when v_months>0 then now()+(v_months||' months')::interval else null end,
               false, true, 1);
        exit;
      exception when unique_violation then v_code:=null; end;
    end loop;
    if v_code is null then return jsonb_build_object('ok',false,'msg','gen'); end if;
    select expires_at into v_exp from cme_users where code=v_code;
    r:=jsonb_build_object('ok',true,'code',v_code,'expires_at',v_exp);

  elsif p_op='extend' then
    v_code:=upper(trim(p_args->>'code')); v_months:=coalesce((p_args->>'months')::int,12);
    update cme_users
      set expires_at = greatest(coalesce(expires_at,now()),now()) + (v_months||' months')::interval
      where upper(code)=v_code and coalesce(is_admin,false)=false and expires_at is not null
      returning expires_at into v_exp;
    if v_exp is null then return jsonb_build_object('ok',false,'msg','life_or_none'); end if;
    r:=jsonb_build_object('ok',true,'expires_at',v_exp);

  elsif p_op='temp' then
    v_code:=upper(trim(p_args->>'code'));
    v_pin:=lpad((floor(random()*9000)+1000)::int::text,4,'0');
    update cme_users set pin=cme_salt(v_code,v_pin), must_set_pin=true, hash_ver=1,
      fail_count=0, locked_until=null
      where upper(code)=v_code and coalesce(is_admin,false)=false;
    if not found then return jsonb_build_object('ok',false,'msg','no_code'); end if;
    delete from cme_sessions where upper(code)=v_code;   -- 원격 로그아웃 효과
    r:=jsonb_build_object('ok',true,'temp',v_pin);

  elsif p_op='del' then
    v_code:=upper(trim(p_args->>'code'));
    delete from cme_items where upper(user_code)=v_code;
    delete from cme_sessions where upper(code)=v_code;
    delete from cme_users where upper(code)=v_code and coalesce(is_admin,false)=false;
    r:=jsonb_build_object('ok',true);

  elsif p_op='setpw' then
    update cme_users set pin=cme_salt(a.code, p_args->>'pw'), hash_ver=1 where code=a.code;
    r:=jsonb_build_object('ok',true);

  else
    r:=jsonb_build_object('ok',false,'msg','op');
  end if;
  return r;
end $function$
;

-- 13) 권한 정리 — RPC만 열고 내부 도우미는 잠금
grant execute on function
  cme_login(text,text), cme_session(text,uuid),
  cme_first_check(text), cme_first(text,text,text), cme_set_pin(text,uuid,text,text),
  cme_items_get(text,uuid), cme_items_upsert(text,uuid,jsonb), cme_items_del(text,uuid,text[]),
  cme_admin(text,text,text,jsonb)
to anon, authenticated;

revoke all on function cme_salt(text,text)        from public, anon, authenticated;
revoke all on function cme_verify(text,text)  from public, anon, authenticated;
revoke all on function cme_sess_ok(text,uuid)     from public, anon, authenticated;
revoke all on function cme_gen_code()             from public, anon, authenticated;

-- ═══ 확인용 (RUN 후 이 두 줄만 따로 실행해보세요) ═══
-- select cme_first_check('없는코드');                      → 'no_code' 나오면 정상
-- select * from cme_users limit 1;                → permission denied 나오면 잠금 성공

-- ═══ 🆘 롤백 (문제 생겼을 때만 아래 주석을 풀고 실행 — 예전 상태로 복귀) ═══
-- alter table cme_users disable row level security;
-- alter table cme_items disable row level security;
-- grant all on table cme_users to anon, authenticated;
-- grant all on table cme_items to anon, authenticated;
