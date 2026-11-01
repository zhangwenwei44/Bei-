-- ============================================================================
-- 横幅云端存储桶（banners）权限收紧 —— 2026-11-01 安全修复（v2.9.11 已验证可用）
--
-- 背景（真实事故）：
--   1) App 里硬编码了"管理员口令"，而那个口令恰好就是管理员云账号的密码
--      → 任何人解压 IPA 就能登录管理员账号；
--   2) banners 桶的写策略放行"任何已登录用户"
--      → 别人登录后把管理员设的横幅换成了自己的图（2026-11-01 19:36 实锤）。
--
-- 目标：只有管理员账号（uid 白名单）能写 / 删横幅；所有设备仍可公开读。
--
-- ⚠️ 关键坑（第一版踩过）：策略里**不能写 `exists (select 1 from auth.users …)`**
--    —— 新版 Supabase 不给 authenticated 角色读 auth.users 表，运行时报
--    "permission denied for table users"，结果是管理员自己也写不了。
--    正确做法：直接比对 `auth.uid()`。
--
-- 用法：Supabase 后台 → SQL Editor → 新建查询 → 粘贴本文件全部内容 → Run
-- ============================================================================

-- 管理员账号：953936355@qq.com
--   uid = e95b7939-a3ac-48a0-a22b-93854251afdc
--   （若管理员账号被重建导致 uid 变化，把下面三处 uid 换成新值；
--     也可以改成 (auth.jwt() ->> 'email') = '953936355@qq.com'）

-- ---------------------------------------------------------------------------
-- 1) 先删掉第一版（引用 auth.users 的）策略
-- ---------------------------------------------------------------------------
drop policy if exists "banners admin insert" on storage.objects;
drop policy if exists "banners admin update" on storage.objects;
drop policy if exists "banners admin delete" on storage.objects;

-- ---------------------------------------------------------------------------
-- 2) 重建：管理员 uid 直判（不查表，不会再报 permission denied）
-- ---------------------------------------------------------------------------
create policy "banners admin insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'banners'
    and auth.uid() = 'e95b7939-a3ac-48a0-a22b-93854251afdc'
  );

create policy "banners admin update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'banners'
    and auth.uid() = 'e95b7939-a3ac-48a0-a22b-93854251afdc'
  )
  with check (
    bucket_id = 'banners'
    and auth.uid() = 'e95b7939-a3ac-48a0-a22b-93854251afdc'
  );

create policy "banners admin delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'banners'
    and auth.uid() = 'e95b7939-a3ac-48a0-a22b-93854251afdc'
  );

-- ---------------------------------------------------------------------------
-- 3) 读：所有设备（含未登录）都能读横幅（公开桶本来就能直取）
--    —— 若第一版已经建好这条就跳过；报 already exists 就忽略
-- ---------------------------------------------------------------------------
-- create policy "banners public read" on storage.objects
--   for select to public
--   using (bucket_id = 'banners');

-- ---------------------------------------------------------------------------
-- 4) 关掉"任何人可自助注册"
--    若这行报错（找不到 auth.config），改用后台：
--    Authentication → Providers → Email → 关闭 "Allow new users to sign up"
-- ---------------------------------------------------------------------------
-- update auth.config set enable_signup = false;

-- ---------------------------------------------------------------------------
-- 5) 检查最终策略清单（应看到 3 条 admin + 1 条 public read）
-- ---------------------------------------------------------------------------
select policyname, cmd, roles, qual, with_check
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
   and (qual like '%banners%' or with_check like '%banners%' or policyname ilike '%banner%');
