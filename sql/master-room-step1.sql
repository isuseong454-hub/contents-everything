-- ══════════════════════════════════════════════════════════════
-- 🏛 마스터 실 step1 — 연동 · 피드백 신청 · 답변
--   양쪽 앱이 같이 쓰는 «공용» 테이블 (마스터즈 접두어 cm_)
--   · 수강생 인증 = _cm_session_code(token)          ← 마스터즈 세션
--   · 강사 인증   = cme_sess_ok(code, token) + is_admin ← 컨모 세션
--   안전: 전부 if not exists · 기존 것 건드리지 않음
-- ══════════════════════════════════════════════════════════════

create table if not exists cm_master_link (
  id           uuid primary key default gen_random_uuid(),
  from_code    text not null unique,
  name         text,
  ig           text,
  intro        text,
  status       text not null default 'pending',   -- pending | linked | rejected | unlinked
  agreed_at    timestamptz,                       -- 정보 제공 동의 시각 (없으면 신청 거부)
  created_at   timestamptz default now(),
  linked_at    timestamptz,
  unlinked_at  timestamptz
);
create index if not exists cm_link_status_idx on cm_master_link(status, created_at desc);

create table if not exists cm_master_req (
  id           uuid primary key default gen_random_uuid(),
  from_code    text not null,
  items        jsonb not null default '[]'::jsonb,
  memo         text,
  status       text not null default 'pending',   -- pending | accepted | rejected | done
  reject_memo  text,
  created_at   timestamptz default now(),
  decided_at   timestamptz
);
create index if not exists cm_req_status_idx on cm_master_req(status, created_at desc);
create index if not exists cm_req_from_idx   on cm_master_req(from_code, created_at desc);

create table if not exists cm_master_fb (
  id           uuid primary key default gen_random_uuid(),
  req_id       uuid references cm_master_req(id) on delete cascade,
  to_code      text not null,
  body         text,
  refs         jsonb default '[]'::jsonb,
  created_at   timestamptz default now(),
  read_at      timestamptz,
  helpful      boolean
);
create index if not exists cm_fb_to_idx on cm_master_fb(to_code, created_at desc);

alter table cm_master_link enable row level security;
alter table cm_master_req  enable row level security;
alter table cm_master_fb   enable row level security;
revoke all on table cm_master_link from anon, authenticated;
revoke all on table cm_master_req  from anon, authenticated;
revoke all on table cm_master_fb   from anon, authenticated;

create or replace function cm_is_master(p_code text, p_token uuid) returns boolean
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  begin c := cme_sess_ok(p_code, p_token); exception when others then return false; end;
  return exists(select 1 from cme_users where upper(code)=upper(c) and is_admin);
end $fn$;

create or replace function cm_link_send(p_token text, p_name text, p_ig text, p_intro text, p_agree boolean)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare c text; cur text;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false,'msg','로그인이 필요해요'); end if;
  if not coalesce(p_agree,false) then return jsonb_build_object('ok',false,'msg','정보 제공에 동의해야 신청할 수 있어요'); end if;
  select status into cur from cm_master_link where from_code=c;
  if cur='linked'  then return jsonb_build_object('ok',false,'msg','이미 연동돼 있어요'); end if;
  if cur='pending' then return jsonb_build_object('ok',false,'msg','이미 신청했어요 — 수락을 기다리는 중입니다'); end if;
  insert into cm_master_link(from_code,name,ig,intro,status,agreed_at,created_at)
  values (c, left(coalesce(p_name,''),30), left(coalesce(p_ig,''),40), left(coalesce(p_intro,''),200), 'pending', now(), now())
  on conflict (from_code) do update
    set name=excluded.name, ig=excluded.ig, intro=excluded.intro,
        status='pending', agreed_at=now(), created_at=now(), unlinked_at=null;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_link_me(p_token text) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare c text; r cm_master_link;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false); end if;
  select * into r from cm_master_link where from_code=c;
  if r.id is null then return jsonb_build_object('ok',true,'status','none'); end if;
  return jsonb_build_object('ok',true,'status',r.status,'name',r.name,'linked_at',r.linked_at);
end $fn$;

create or replace function cm_link_list(p_code text, p_token uuid, p_status text default null)
returns setof cm_master_link language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then raise exception 'not_master'; end if;
  return query select * from cm_master_link
    where (p_status is null or status=p_status)
    order by (status='pending') desc, created_at desc;
end $fn$;

create or replace function cm_link_decide(p_code text, p_token uuid, p_from text, p_ok boolean)
returns jsonb language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then return jsonb_build_object('ok',false,'msg','권한이 없어요'); end if;
  update cm_master_link
     set status = case when p_ok then 'linked' else 'rejected' end,
         linked_at = case when p_ok then now() else linked_at end
   where from_code = p_from;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_link_off(p_code text, p_token uuid, p_from text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then return jsonb_build_object('ok',false,'msg','권한이 없어요'); end if;
  update cm_master_link set status='unlinked', unlinked_at=now() where from_code=p_from;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_link_off_me(p_token text) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false); end if;
  update cm_master_link set status='unlinked', unlinked_at=now() where from_code=c;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_link_stats(p_code text, p_token uuid, p_from text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare st text; tot int; wks int; best int; fol int; recent jsonb;
begin
  if not cm_is_master(p_code,p_token) then return jsonb_build_object('ok',false,'msg','권한이 없어요'); end if;
  select status into st from cm_master_link where from_code=p_from;
  if st is distinct from 'linked' then return jsonb_build_object('ok',false,'msg','연동된 수강생만 볼 수 있어요'); end if;
  select coalesce(sum(uploads),0), count(*), coalesce(max(best_views),0)
    into tot, wks, best from cm_weekly_stats where user_code=p_from;
  select followers into fol from cm_weekly_stats where user_code=p_from order by wk desc limit 1;
  select coalesce(jsonb_agg(x),'[]'::jsonb) into recent from (
    select jsonb_build_object('wk',wk,'followers',followers,'best',best_views,'uploads',uploads) as x
    from cm_weekly_stats where user_code=p_from order by wk desc limit 4
  ) t;
  return jsonb_build_object('ok',true,
    'uploads_total', tot,
    'weeks', wks,
    'uploads_per_week', case when wks>0 then round(tot::numeric/wks,1) else 0 end,
    'best_views', best,
    'followers', coalesce(fol,0),
    'recent', recent);
end $fn$;

create or replace function cm_req_send(p_token text, p_items jsonb, p_memo text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare c text; st text; waiting int;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false,'msg','로그인이 필요해요'); end if;
  select status into st from cm_master_link where from_code=c;
  if st is distinct from 'linked' then return jsonb_build_object('ok',false,'msg','먼저 마스터와 연동해야 해요'); end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 3 then return jsonb_build_object('ok',false,'msg','최대 3개까지 보낼 수 있어요'); end if;
  select count(*) into waiting from cm_master_req where from_code=c and status in ('pending','accepted');
  if waiting > 0 then return jsonb_build_object('ok',false,'msg','아직 답을 기다리는 신청이 있어요'); end if;
  insert into cm_master_req(from_code,items,memo) values (c, coalesce(p_items,'[]'::jsonb), left(coalesce(p_memo,''),200));
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_req_list(p_code text, p_token uuid, p_status text default null)
returns setof cm_master_req language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then raise exception 'not_master'; end if;
  return query select * from cm_master_req
    where (p_status is null or status=p_status)
    order by (status='pending') desc, created_at desc;
end $fn$;

create or replace function cm_req_decide(p_code text, p_token uuid, p_id uuid, p_ok boolean, p_memo text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then return jsonb_build_object('ok',false,'msg','권한이 없어요'); end if;
  update cm_master_req
     set status = case when p_ok then 'accepted' else 'rejected' end,
         reject_memo = case when p_ok then null else left(coalesce(p_memo,''),200) end,
         decided_at = now()
   where id = p_id;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_req_mine(p_token text) returns setof cm_master_req
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  c := _cm_session_code(p_token);
  if c is null then return; end if;
  return query select * from cm_master_req where from_code=c order by created_at desc limit 20;
end $fn$;

create or replace function cm_fb_send(p_code text, p_token uuid, p_req uuid, p_body text, p_refs jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare tgt text;
begin
  if not cm_is_master(p_code,p_token) then return jsonb_build_object('ok',false,'msg','권한이 없어요'); end if;
  select from_code into tgt from cm_master_req where id=p_req;
  if tgt is null then return jsonb_build_object('ok',false,'msg','신청을 찾을 수 없어요'); end if;
  insert into cm_master_fb(req_id,to_code,body,refs) values (p_req, tgt, p_body, coalesce(p_refs,'[]'::jsonb));
  update cm_master_req set status='done', decided_at=now() where id=p_req;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_fb_list(p_token text) returns setof cm_master_fb
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  c := _cm_session_code(p_token);
  if c is null then return; end if;
  return query select * from cm_master_fb where to_code=c order by created_at desc limit 50;
end $fn$;

create or replace function cm_fb_read(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false); end if;
  update cm_master_fb set read_at=coalesce(read_at,now()) where id=p_id and to_code=c;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_fb_helpful(p_token text, p_id uuid, p_v boolean) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare c text;
begin
  c := _cm_session_code(p_token);
  if c is null then return jsonb_build_object('ok',false); end if;
  update cm_master_fb set helpful=p_v where id=p_id and to_code=c;
  return jsonb_build_object('ok',true);
end $fn$;

create or replace function cm_fb_sent(p_code text, p_token uuid) returns setof cm_master_fb
language plpgsql security definer set search_path=public as $fn$
begin
  if not cm_is_master(p_code,p_token) then raise exception 'not_master'; end if;
  return query select * from cm_master_fb order by created_at desc limit 100;
end $fn$;

grant execute on function cm_link_send(text,text,text,text,boolean) to anon, authenticated;
grant execute on function cm_link_me(text) to anon, authenticated;
grant execute on function cm_link_off_me(text) to anon, authenticated;
grant execute on function cm_link_list(text,uuid,text) to anon, authenticated;
grant execute on function cm_link_decide(text,uuid,text,boolean) to anon, authenticated;
grant execute on function cm_link_off(text,uuid,text) to anon, authenticated;
grant execute on function cm_link_stats(text,uuid,text) to anon, authenticated;
grant execute on function cm_req_send(text,jsonb,text) to anon, authenticated;
grant execute on function cm_req_mine(text) to anon, authenticated;
grant execute on function cm_req_list(text,uuid,text) to anon, authenticated;
grant execute on function cm_req_decide(text,uuid,uuid,boolean,text) to anon, authenticated;
grant execute on function cm_fb_send(text,uuid,uuid,text,jsonb) to anon, authenticated;
grant execute on function cm_fb_list(text) to anon, authenticated;
grant execute on function cm_fb_read(text,uuid) to anon, authenticated;
grant execute on function cm_fb_helpful(text,uuid,boolean) to anon, authenticated;
grant execute on function cm_fb_sent(text,uuid) to anon, authenticated;

revoke all on function cm_is_master(text,uuid) from public, anon, authenticated;
