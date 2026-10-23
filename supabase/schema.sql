-- 대련 맛집 지도 백엔드 (Supabase / PostgreSQL)
-- Supabase 대시보드 > SQL Editor에 통째로 붙여 넣고 한 번 실행한다. 여러 번 실행해도 안전하다(이미 있으면 건너뜀).
--
-- 규칙 요약
--   읽기: 누구나(로그인 없이) 숨기지 않은 댓글과 승인된 제안을 읽을 수 있다.
--   쓰기: 관리자가 승인한 사람만 댓글·제안·사진 업로드를 할 수 있다.
--   관리자: admins 표에 있는 사람. 마지막 관리자는 해제할 수 없다(인수인계 중 관리자가 0명이 되는 사고 방지).

------------------------------------------------------------------ 표
create table if not exists public.profiles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  email        text,
  display_name text not null default '',
  status       text not null default 'pending' check (status in ('pending', 'approved', 'blocked')),
  created_at   timestamptz not null default now()
);

create table if not exists public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.comments (
  id          bigint generated always as identity primary key,
  place_no    text not null,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  author_name text not null default '',
  body        text not null check (char_length(body) between 1 and 1000),
  hidden      boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists comments_place_idx on public.comments (place_no, created_at);

create table if not exists public.suggestions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  author_name text not null default '',
  ko          text not null check (char_length(ko) between 1 and 100),
  zh          text not null default '' check (char_length(zh) <= 200),
  lat         numeric,
  lon         numeric,
  price       text not null default '' check (char_length(price) <= 40),
  kind        text not null default '' check (char_length(kind) <= 60),
  menu        text not null default '' check (char_length(menu) <= 300),
  note        text not null default '' check (char_length(note) <= 1500),
  photos      text[] not null default '{}' check (coalesce(array_length(photos, 1), 0) <= 10),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  admin_note  text not null default '',
  created_at  timestamptz not null default now()
);

------------------------------------------------------------------ 도우미 함수
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where user_id = auth.uid() and status = 'approved');
$$;

-- 가입하면 승인 대기(pending) 프로필을 자동으로 만든다
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, email, display_name)
  values (new.id, new.email, left(coalesce(new.raw_user_meta_data ->> 'name', ''), 40))
  on conflict (user_id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 작성자 이름은 프로필에서 서버가 채운다(화면에서 속일 수 없게).
create or replace function public.fill_author() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select display_name into new.author_name from public.profiles where user_id = new.user_id;
  return new;
end;
$$;
drop trigger if exists comments_fill on public.comments;
create trigger comments_fill before insert on public.comments
  for each row execute function public.fill_author();
drop trigger if exists suggestions_fill on public.suggestions;
create trigger suggestions_fill before insert on public.suggestions
  for each row execute function public.fill_author();
-- 예전 버전(하루 한도)이 있었다면 정리
drop function if exists public.fill_author_and_limit();

-- 관리자 지정/해제 (관리자만 호출 가능). 인수인계는 이 두 함수로 한다.
create or replace function public.grant_admin(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '관리자만 할 수 있습니다'; end if;
  update public.profiles set status = 'approved' where user_id = target;
  insert into public.admins (user_id) values (target) on conflict do nothing;
end;
$$;

create or replace function public.revoke_admin(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '관리자만 할 수 있습니다'; end if;
  if (select count(*) from public.admins) <= 1 then raise exception '마지막 관리자는 해제할 수 없습니다. 먼저 다음 관리자를 지정하세요'; end if;
  delete from public.admins where user_id = target;
end;
$$;

-- 함수는 로그인한 사람만 부를 수 있게 한다
revoke all on function public.grant_admin(uuid), public.revoke_admin(uuid) from public, anon;
grant execute on function public.grant_admin(uuid), public.revoke_admin(uuid) to authenticated;
grant execute on function public.is_admin(), public.is_approved() to anon, authenticated;

------------------------------------------------------------------ 행 단위 보안(RLS)
alter table public.profiles    enable row level security;
alter table public.admins      enable row level security;
alter table public.comments    enable row level security;
alter table public.suggestions enable row level security;

-- profiles: 본인 것 읽기, 관리자는 전체 읽기·상태 변경
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (user_id = auth.uid());
drop policy if exists profiles_select_admin on public.profiles;
create policy profiles_select_admin on public.profiles for select to authenticated using (public.is_admin());
drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- admins: 관리자만 목록 읽기 (지정·해제는 위 함수로만)
drop policy if exists admins_select on public.admins;
create policy admins_select on public.admins for select to authenticated using (public.is_admin());

-- comments: 누구나 읽기(숨김 제외), 승인된 사람만 쓰기, 본인 또는 관리자만 삭제, 관리자만 숨기기
drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select to anon, authenticated using (hidden = false or public.is_admin());
drop policy if exists comments_insert on public.comments;
create policy comments_insert on public.comments for insert to authenticated with check (user_id = auth.uid() and public.is_approved() and hidden = false);
drop policy if exists comments_update_admin on public.comments;
create policy comments_update_admin on public.comments for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments for delete to authenticated using (user_id = auth.uid() or public.is_admin());

-- suggestions: 누구나 승인된 것만 읽기, 승인된 사람만 쓰기(항상 대기 상태로). 수정·삭제는 아래 '본인 글 수정' 절 참고
drop policy if exists suggestions_select on public.suggestions;
create policy suggestions_select on public.suggestions for select to anon, authenticated
  using (status = 'approved' or user_id = auth.uid() or public.is_admin());
drop policy if exists suggestions_insert on public.suggestions;
create policy suggestions_insert on public.suggestions for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved() and status = 'pending');
drop policy if exists suggestions_update_admin on public.suggestions;
create policy suggestions_update_admin on public.suggestions for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists suggestions_delete on public.suggestions;
create policy suggestions_delete on public.suggestions for delete to authenticated
  using (public.is_admin() or (user_id = auth.uid() and status = 'pending'));

------------------------------------------------------------------ 사진 저장소
-- 공개 저장소. 올릴 수 있는 사람은 승인된 사람, 자기 폴더(user_id/)에만. 파일 하나 500KB, webp/jpeg만.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 512000, array['image/webp', 'image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 512000, allowed_mime_types = array['image/webp', 'image/jpeg'];

drop policy if exists photos_insert on storage.objects;
create policy photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.is_approved() and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists photos_delete on storage.objects;
create policy photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

------------------------------------------------------------------ 본인 글 수정·삭제
-- 승인된 사람은 자기가 쓴 댓글의 내용과, 자기가 낸 제안의 내용·사진을 고칠 수 있다.
-- 고칠 수 없는 항목(상태, 관리자 메모, 작성자, 숨김 여부, 어느 가게의 댓글인지)은 아래 트리거가 원래 값으로 되돌린다.
alter table public.comments    add column if not exists updated_at timestamptz;
alter table public.suggestions add column if not exists updated_at timestamptz;

create or replace function public.guard_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then
    return new;                                   -- 관리자는 제한 없음
  end if;
  new.user_id := old.user_id; new.author_name := old.author_name; new.created_at := old.created_at;
  if tg_table_name = 'comments' then
    new.place_no := old.place_no; new.hidden := old.hidden;
    new.updated_at := case when new.body is distinct from old.body then now() else old.updated_at end;
  else
    new.status := old.status; new.admin_note := old.admin_note;
    new.updated_at := case when (new.ko, new.zh, new.lat, new.lon, new.price, new.kind, new.menu, new.note, new.photos)
                              is distinct from (old.ko, old.zh, old.lat, old.lon, old.price, old.kind, old.menu, old.note, old.photos)
                           then now() else old.updated_at end;
  end if;
  return new;
end;
$$;
drop trigger if exists comments_guard on public.comments;
create trigger comments_guard before update on public.comments for each row execute function public.guard_update();
drop trigger if exists suggestions_guard on public.suggestions;
create trigger suggestions_guard before update on public.suggestions for each row execute function public.guard_update();

drop policy if exists comments_update_own on public.comments;
create policy comments_update_own on public.comments for update to authenticated
  using (user_id = auth.uid() and public.is_approved()) with check (user_id = auth.uid());
drop policy if exists suggestions_update_own on public.suggestions;
create policy suggestions_update_own on public.suggestions for update to authenticated
  using (user_id = auth.uid() and public.is_approved()) with check (user_id = auth.uid());

-- 제안은 본인이 언제든 삭제할 수 있다(이전에는 대기 중인 것만)
drop policy if exists suggestions_delete on public.suggestions;
create policy suggestions_delete on public.suggestions for delete to authenticated
  using (public.is_admin() or user_id = auth.uid());
