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

