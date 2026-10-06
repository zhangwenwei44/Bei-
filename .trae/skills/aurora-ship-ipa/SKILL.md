---
name: aurora-ship-ipa
description: AuroraMusic 发包流程——等待 GitHub Actions CI、下载 unsigned IPA artifact、替换 v2.5.0 Release 里的 IPA 资产并给出下载地址。当用户在 Bei- 仓库改完代码后要求发包、打包、发下载地址、走 CI 出 IPA 时使用。不用于本地构建或其他仓库。
---

# AuroraMusic 发包（CI → artifact → Release IPA）

在 Bei- 仓库（zhangwenwei44/Bei-）完成代码改动后，按此流程把新 IPA 发到 GitHub Release。

## 流程

1. **提交推送**（仅当用户要求发包，且用户已明确允许提交时）：
   - `git add -A`，commit message 用中文简述改动，`git push origin main`。
   - 本机 Windows PowerShell 5.x 不支持 `&&`，用 `;` + `if ($?)` 串联，或直接运行 scripts/ship-ipa.ps1（脚本内部不负责提交）。
2. **一键发包**：运行脚本（默认处理 main 分支最新一次 CI）：
   `powershell -ExecutionPolicy Bypass -File .trae/skills/aurora-ship-ipa/scripts/ship-ipa.ps1`
   - 脚本自动：取 GitHub token（git credential fill）→ 定位/轮询最新 CI run → 成功则下载 artifact `AuroraMusic-unsigned-ipa`（zip 内是 .ipa）→ 删除 Release（id 404702255）旧资产 `AuroraMusic-v2.5.0.ipa` → 上传新 IPA → 打印下载地址。
   - 指定 run：`-RunId <id>`；CI 失败时脚本退出码 1，并打印失败步骤日志里的 `error:` 行。
3. **CI 失败处理**：根据脚本输出的编译错误修代码（先看本仓库常见坑，见下），重新 commit/push 后再跑脚本。CI warning 也算失败，提交前确保无未使用变量/未穷尽 switch。
4. 成功后把下载地址发给用户：
   `https://github.com/zhangwenwei44/Bei-/releases/download/v2.5.0/AuroraMusic-v2.5.0.ipa`
   Release 是固定 tag v2.5.0、资产名固定覆盖，用户重装即可，不需要新建 Release。

## 本仓库踩过的坑（排查 CI 失败优先对照）

- Swift 字段名：歌曲专辑 id 是 `song.kugouAlbumID`（不是 albumID）；`Album` 模型才有 `albumID`。
- 新增 enum case 后，所有 `switch section` / `switch self` 都要补分支，否则 "switch must be exhaustive"。
- 不要加 `.fixedSize(vertical: true)`（GeometryReader 会撑超高）。
- `/plist/index` 的 `json=true` 必须放 params（queryItems 会覆盖 path 内查询串）。
- mobilecdn.kugou.com 在部分网络证书不匹配/不可达；优先用 mobiles.kugou.com（与搜索同主机，设备实测可达）。
- 未使用的私有变量/函数会产生 warning 进而导致 CI 失败，删除之。

## 环境备注

- token 获取等价于：`"protocol=https`nhost=github.com`n`n" | git credential fill`，取 `password=` 行。注意在 `powershell -File` 子进程里该管道不可靠（git 报 missing protocol field），脚本里改为写临时 ASCII 文件 + `cmd /c "git credential fill < file"`。
- 下载 job 日志：API 会 302 到 productionresultssa blob，需禁止自动跟随取 Location，再用 `curl.exe --ssl-no-revoke` 下载（本机 curl 直连该域名会 exit 35）。
- 上传资产走 uploads.github.com，POST `.../assets?name=<AssetName>`，Content-Type application/octet-stream。
