-- 2026-10-26 업데이트: (1) 이미 있는 가게에 내용 추가(target_place) (2) 기본 가게 수정(place_edits). 여러 번 실행해도 안전하다.

-- 이미 있는 가게에 내용 추가: 제안(suggestions)에 '대상 가게' 열을 넣는다. 여러 번 실행해도 안전하다.
alter table public.suggestions add column if not exists target_place text not null default '' check (char_length(target_place) <= 40);

-- 일반 사용자가 고칠 수 없는 항목에 '대상 가게'를 추가한다(기존 함수를 교체)
create or replace function public.guard_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then
    return new;
  end if;
  new.user_id := old.user_id; new.author_name := old.author_name; new.created_at := old.created_at;
  if tg_table_name = 'comments' then
    new.place_no := old.place_no; new.hidden := old.hidden;
    new.updated_at := case when new.body is distinct from old.body then now() else old.updated_at end;
  else
    new.status := old.status; new.admin_note := old.admin_note; new.target_place := old.target_place;
    new.updated_at := case when (new.ko, new.zh, new.lat, new.lon, new.price, new.kind, new.menu, new.note, new.photos)
                              is distinct from (old.ko, old.zh, old.lat, old.lon, old.price, old.kind, old.menu, old.note, old.photos)
                           then now() else old.updated_at end;
  end if;
  return new;
end;
$$;

------------------------------------------------------------------ 기본 가게 수정(관리자가 고친 내용을 기본 데이터 위에 덮어쓴다)
-- 기본 가게(data/restaurants.json)의 글·사진·위치를 사이트에서 고치면 여기에 저장된다. 비어 있는(null) 항목은 원래 값을 쓴다.
create table if not exists public.place_edits (
  place_id   text primary key check (char_length(place_id) <= 40),
  ko         text check (ko is null or char_length(ko) between 1 and 100),
  zh         text check (zh is null or char_length(zh) <= 200),
  kind       text check (kind is null or char_length(kind) <= 60),
  price      text check (price is null or char_length(price) <= 40),
  menu       text check (menu is null or char_length(menu) <= 300),
  note       text check (note is null or char_length(note) <= 1500),
  photos     text[] check (photos is null or coalesce(array_length(photos, 1), 0) <= 30),
  lat        numeric,
  lon        numeric,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);
alter table public.place_edits enable row level security;
drop policy if exists place_edits_select on public.place_edits;
create policy place_edits_select on public.place_edits for select to anon, authenticated using (true);
drop policy if exists place_edits_write on public.place_edits;
create policy place_edits_write on public.place_edits for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.touch_place_edit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now(); new.updated_by := auth.uid();
  return new;
end;
$$;
drop trigger if exists place_edits_touch on public.place_edits;
create trigger place_edits_touch before insert or update on public.place_edits for each row execute function public.touch_place_edit();
