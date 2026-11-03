-- '맛있어요' 기능: 승인된 선생님만 가게마다 한 번씩 누를 수 있고, 개수는 누구나 본다.
-- Supabase 대시보드 > SQL Editor 에 붙여 넣고 Run. 여러 번 실행해도 안전하다.

create table if not exists public.likes (
  place_id   text not null,                                   -- 가게 번호(기본 가게 '1', 선생님이 올린 가게 's12')
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)                             -- 한 사람이 같은 가게에 한 번만
);

alter table public.likes enable row level security;
grant select, insert, delete on public.likes to authenticated;

-- 누가 눌렀는지는 본인 것만 볼 수 있다(개수는 아래 like_counts 로 공개)
drop policy if exists likes_select_own on public.likes;
create policy likes_select_own on public.likes for select to authenticated using (user_id = auth.uid());
drop policy if exists likes_insert on public.likes;
create policy likes_insert on public.likes for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved());
drop policy if exists likes_delete_own on public.likes;
create policy likes_delete_own on public.likes for delete to authenticated using (user_id = auth.uid());

-- 로그인하지 않은 사람도 볼 수 있는 가게별 개수
create or replace view public.like_counts as
  select place_id, count(*)::int as n from public.likes group by place_id;
grant select on public.like_counts to anon, authenticated;
