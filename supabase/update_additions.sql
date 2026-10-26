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
