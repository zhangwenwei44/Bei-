-- ============================================================
-- Aurora Music 云同步表结构
-- 在 Supabase 后台 → SQL Editor 粘贴本文件，点「Run」执行一次即可。
-- 用途：保存每个用户的收藏与自建歌单，配合 App 内的 RLS 行级权限实现数据隔离。
-- ============================================================

-- 1) 收藏表：每行一首歌，song 字段把整首歌的信息（标题/歌手/封面/来源等）以 JSON 存下来
create table if not exists public.favorites (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users(id) on delete cascade,
  song_id    text        not null,
  song       jsonb       not null,
  created_at timestamptz not null default now()
);
create unique index if not exists favorites_user_song
  on public.favorites (user_id, song_id);

-- 2) 歌单表：每行一个歌单，songs 字段以 JSON 数组存该歌单的完整歌曲列表
create table if not exists public.playlists (
  id         text        not null,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  name       text        not null,
  songs      jsonb       not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

-- 3) 行级权限（RLS）：每个登录用户只能读写自己的数据
alter table public.favorites enable row level security;
alter table public.playlists enable row level security;

drop policy if exists "favorites own" on public.favorites;
create policy "favorites own" on public.favorites
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "playlists own" on public.playlists;
create policy "playlists own" on public.playlists
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 4) 客户端角色（authenticated）权限，供 App 通过 Data API 读写
grant select, insert, update, delete on public.favorites to authenticated;
grant select, insert, update, delete on public.playlists to authenticated;
