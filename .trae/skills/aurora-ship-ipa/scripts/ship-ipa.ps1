<#
.SYNOPSIS
  AuroraMusic ship: wait for CI -> download unsigned IPA artifact -> replace release asset.
  Default repo zhangwenwei44/Bei-, release id 404702255 (v2.5.0).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .trae/skills/aurora-ship-ipa/scripts/ship-ipa.ps1
.EXAMPLE
  ./ship-ipa.ps1 -RunId 37502678455
#>
param(
    [string]$Repo = "zhangwenwei44/Bei-",
    [string]$ReleaseId = "404702255",
    [string]$AssetName = "AuroraMusic-v2.5.0.ipa",
    [string]$ArtifactName = "AuroraMusic-unsigned-ipa",
    [string]$Branch = "main",
    [string]$RunId = "",
    [int]$PollSeconds = 20,
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"

function Get-GitHubToken {
    # Direct PS pipes to native stdin are unreliable in this PS 5.1 environment,
    # so feed git through a temp file with cmd's input redirect.
    $inFile = Join-Path $env:TEMP "aurora-cred-in.txt"
    [System.IO.File]::WriteAllText($inFile, "protocol=https`nhost=github.com`n`n", [System.Text.Encoding]::ASCII)
    $raw = cmd /c "git credential fill < `"$inFile`" 2>&1"
    foreach ($line in $raw) {
        if ($line -like "password=*") { return $line.Substring("password=".Length) }
    }
    throw "git credential fill did not return a github token"
}

$token = Get-GitHubToken
$headers = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
$apiBase = "https://api.github.com/repos/$Repo"

# 1. Locate the CI run
if (-not $RunId) {
    $runs = Invoke-RestMethod -Headers $headers -Uri "$apiBase/actions/runs?branch=$Branch&per_page=1"
    if (-not $runs.workflow_runs -or $runs.workflow_runs.Count -eq 0) { throw "No CI run found for branch $Branch" }
    $RunId = $runs.workflow_runs[0].id
}
Write-Host "CI run: $RunId"

# 2. Poll until completed
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ($true) {
    $run = Invoke-RestMethod -Headers $headers -Uri "$apiBase/actions/runs/$RunId"
    if ($run.status -eq "completed") { break }
    Write-Host "  status=$($run.status), retry in ${PollSeconds}s ..."
    if ((Get-Date) -gt $deadline) { throw "CI poll timed out after $TimeoutMinutes minutes" }
    Start-Sleep -Seconds $PollSeconds
}
Write-Host "CI completed: conclusion=$($run.conclusion)"

if ($run.conclusion -ne "success") {
    # 3. Failure: dump failed-step logs
    $jobs = Invoke-RestMethod -Headers $headers -Uri "$apiBase/actions/runs/$RunId/jobs"
    foreach ($job in $jobs.jobs) {
        if ($job.conclusion -ne "failure") { continue }
        Write-Host ""
        Write-Host "== JOB: $($job.name) =="
        foreach ($step in $job.steps) {
            if ($step.conclusion -eq "failure") { Write-Host "Failed step: $($step.name)" }
        }
        # Job logs API 302-redirects to a blob host; read Location manually, then use curl --ssl-no-revoke
        $req = [System.Net.HttpWebRequest]::Create("$apiBase/actions/jobs/$($job.id)/logs")
        $req.AllowAutoRedirect = $false
        $req.Headers.Add("Authorization", "token $token")
        $req.Accept = "application/vnd.github+json"
        $req.UserAgent = "aurora-ship"
        try { $resp = $req.GetResponse() } catch { $resp = $_.Exception.Response }
        $signed = $resp.Headers["Location"]
        if ($signed) {
            $logFile = Join-Path $env:TEMP "aurora-ci-$($job.id).log"
            & curl.exe -s --ssl-no-revoke $signed -o $logFile
            Write-Host "-- compile errors --"
            Select-String -Path $logFile -Pattern ": error:" | Select-Object -First 30 -ExpandProperty Line
        }
    }
    exit 1
}

# 4. Download the artifact
$artifacts = Invoke-RestMethod -Headers $headers -Uri "$apiBase/actions/runs/$RunId/artifacts"
$artifact = $artifacts.artifacts | Where-Object { $_.name -eq $ArtifactName } | Select-Object -First 1
if (-not $artifact) { throw "Artifact $ArtifactName not found in run $RunId" }
$sizeKB = [math]::Round($artifact.size_in_bytes / 1KB)
Write-Host "Downloading artifact: $($artifact.name) ($sizeKB KB)"

$staging = Join-Path $env:TEMP "aurora-ship-$RunId"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null
$zipPath = Join-Path $staging "artifact.zip"
Invoke-WebRequest -Headers $headers -Uri $artifact.archive_download_url -OutFile $zipPath
Expand-Archive $zipPath -DestinationPath $staging -Force
$ipa = Get-ChildItem $staging -Recurse -Filter "*.ipa" | Select-Object -First 1
if (-not $ipa) { throw "No .ipa found inside the artifact zip" }
$sizeMB = [math]::Round($ipa.Length / 1MB, 2)
Write-Host "IPA: $($ipa.Name) ($sizeMB MB)"

# 5. Delete the old asset with the same name
$release = Invoke-RestMethod -Headers $headers -Uri "$apiBase/releases/$ReleaseId"
$old = $release.assets | Where-Object { $_.name -eq $AssetName }
if ($old) {
    Invoke-RestMethod -Headers $headers -Method Delete -Uri "$apiBase/releases/assets/$($old.id)" | Out-Null
    Write-Host "Deleted old asset id=$($old.id)"
}

# 6. Upload the new asset
$bytes = [System.IO.File]::ReadAllBytes($ipa.FullName)
$upReq = [System.Net.HttpWebRequest]::Create("https://uploads.github.com/repos/$Repo/releases/$ReleaseId/assets?name=$AssetName")
$upReq.Method = "POST"
$upReq.Headers.Add("Authorization", "token $token")
$upReq.Accept = "application/vnd.github+json"
$upReq.ContentType = "application/octet-stream"
$upReq.ContentLength = $bytes.Length
$reqStream = $upReq.GetRequestStream()
$reqStream.Write($bytes, 0, $bytes.Length)
$reqStream.Close()
$upResp = $upReq.GetResponse()
$reader = New-Object System.IO.StreamReader($upResp.GetResponseStream())
$assetInfo = $reader.ReadToEnd() | ConvertFrom-Json
$reader.Close()

Write-Host ""
Write-Host "SHIPPED: $($assetInfo.browser_download_url)"
