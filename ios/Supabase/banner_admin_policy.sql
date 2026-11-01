-- ============================================================================
-- 横幅云端存储桶（banners）权限收紧 —— 2026-11-01 安全修复
--
-- 背景（真实事故）：
--   1) App 里硬编码了"管理员口令"，而那个口令恰好就是管理员云账号的密码
--      → 任何人解压 IPA 就能登录管理员账号；
--   2) banners 桶的写策略放行"任何已登录用户"
--      → 别人登录后把管理员设的横幅换成了自己的图（2026-11-01 19:36 实锤）。
--
-- 目标：只有管理员账号（邮箱白名单）能写 / 删横幅；所有设备仍可公开读。
--
-- 用法：Supabase 后台 → SQL Editor → 新建查询 → 粘贴本文件全部内容 → Run
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) 先看看现在有哪些策略作用于 banners（结果看一眼就行，不影响执行）
-- ---------------------------------------------------------------------------
select policyname, cmd, qual, with_check
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
   and (qual like '%banners%' or with_check like '%banners%' or policyname ilike '%banner%');

-- ---------------------------------------------------------------------------
-- 2) 删掉所有作用于 banners 桶的旧策略（动态删，不用记策略名字）
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select policyname from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (qual like '%banners%' or with_check like '%banners%' or policyname ilike '%banner%')
  loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3) 管理员专属写权限：insert / update / delete 都只放行管理员账号
--    （邮箱白名单与 App 内 SupabaseConfig.adminEmail 保持一致）
-- ---------------------------------------------------------------------------
create policy "banners admin insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'banners'
    and exists (
      select 1 from auth.users u
       where u.id = auth.uid() and lower(u.email) = '953936355@qq.com'
    )
  );

create policy "banners admin update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'banners'
    and exists (
      select 1 from auth.users u
       where u.id = auth.uid() and lower(u.email) = '953936355@qq.com'
    )
  )
  with check (
    bucket_id = 'banners'
    and exists (
      select 1 from auth.users u
       where u.id = auth.uid() and lower(u.email) = '953936355@qq.com'
    )
  );

create policy "banners admin delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'banners'
    and exists (
      select 1 from auth.users u
       where u.id = auth.uid() and lower(u.email) = '953936355@qq.com'
    )
  );

-- ---------------------------------------------------------------------------
-- 4) 读：所有设备（含未登录）都能读横幅 —— 公开桶本来就能直取，
--    这里补一条 select 策略，保证列表接口也能用
-- ---------------------------------------------------------------------------
create policy "banners public read" on storage.objects
  for select to public
  using (bucket_id = 'banners');

-- ---------------------------------------------------------------------------
-- 5) 顺手关掉"任何人可自助注册"（免得再有人注册进来试）
--    若这行报错（找不到 auth.config），改用后台：
--    Authentication → Providers → Email → 关闭 "Allow new users to sign up"
-- ---------------------------------------------------------------------------
-- update auth.config set enable_signup = false;

-- ---------------------------------------------------------------------------
-- 6) 验证（Run 完最后跑这句，应该显示你的管理员邮箱）
-- ---------------------------------------------------------------------------
select auth.uid() as current_uid,
       (select email from auth.users where id = auth.uid()) as email;
