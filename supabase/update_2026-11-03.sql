-- 2026-11-03: 가게 글(새 가게·가게에 추가한 내용)은 승인 없이 바로 공개한다. 가입 승인은 그대로다. 문제가 있으면 관리자가 숨긴다(status = rejected).
alter table public.suggestions alter column status set default 'approved';
drop policy if exists suggestions_insert on public.suggestions;
create policy suggestions_insert on public.suggestions for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved() and status = 'approved');
