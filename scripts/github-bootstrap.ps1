# GitHub bootstrap push for this machine (github.com is DNS-sinkholed to 127.0.0.1 here).
#   1) api.github.com       - register SSH key + create private repo (with retry)
#   2) ssh.github.com:443   - push code (this hostname is NOT poisoned)
# Requires: a GitHub credential stored by Git Credential Manager in the Windows
# credential store, and ~/.ssh/github_beautyinapple key pair.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/github-bootstrap.ps1 [repoName]
$ErrorActionPreference = 'Stop'
$RepoName = if ($Args.Count -ge 1) { $Args[0] } else { 'imagecake-apple' }
$repoRoot = Split-Path -Parent $PSScriptRoot

# ---- 1. ssh_config: route github.com over ssh.github.com:443 with a dedicated key ----
$configPath = "$env:USERPROFILE\.ssh\config"
if (-not (Test-Path $configPath)) { New-Item $configPath -ItemType File | Out-Null }
if ((Get-Content $configPath -Raw) -notmatch 'BeautyInApple-github-ssh') {
    Add-Content -Path $configPath -Value (@(
        '# BeautyInApple-github-ssh',
        'Host github.com',
        '    HostName ssh.github.com',
        '    Port 443',
        '    User git',
        '    IdentityFile ~/.ssh/github_beautyinapple',
        '    IdentitiesOnly yes',
        '    ServerAliveInterval 20'
    ) -join "`n")
    "ssh-config: added github.com -> ssh.github.com:443 block"
} else { "ssh-config: block already present, skipped" }

# ---- 2. token from the Windows credential store (never printed) ----
function Get-Token {
    $out = "protocol=https`nhost=github.com`n" -replace '`n', "`n" |
        & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
    ($out | Select-String '^password=').ToString().Substring(9)
}
$token = Get-Token

# PS 5.1 Invoke-RestMethod flakes on this network; curl.exe is the stable engine here.
$script:HdrFile = Join-Path $env:TEMP 'gh-bootstrap-header.txt'
Set-Content -Path $script:HdrFile -Value (@("header = `"Authorization: token $token`"", 'header = "Accept: application/vnd.github+json"')) -Encoding ASCII

function Invoke-GitHubWithRetry([string]$Uri, [string]$Method = 'GET', $Body = $null) {
    $bodyFile = Join-Path $env:TEMP 'gh-bootstrap-body.json'
    for ($i = 1; $i -le 8; $i++) {
        $curlArgs = @('-sS', '--config', $script:HdrFile, '-X', $Method, '-w', "`nHTTPSTATUS:%{http_code}", '--connect-timeout', '15', '--max-time', '40')
        if ($null -ne $Body) {
            Set-Content -Path $bodyFile -Value ($Body | ConvertTo-Json) -Encoding ASCII
            $curlArgs = $curlArgs + @('-H', 'Content-Type: application/json', '--data', ('@' + $bodyFile))
        }
        $curlArgs = $curlArgs + @($Uri)
        $raw = (& curl.exe @curlArgs 2>&1) -join "`n"
        if ($raw -match "(?s)^(.*)`nHTTPSTATUS:(\d{3})$") {
            $bodyText = $Matches[1]; $status = [int]$Matches[2]
            if ($status -ge 200 -and $status -lt 300) {
                if ($bodyText.Trim().Length -eq 0) { return $null }
                return ($bodyText | ConvertFrom-Json)
            }
            # 4xx are deterministic answers, not transport flakes: surface them at once.
            if ($status -eq 404 -or $status -eq 422) { throw "HTTP $status on $Uri" }
            "  attempt $i : HTTP $status -> retry"
        } else {
            "  attempt $i : transport error -> retry"
        }
        Start-Sleep -Seconds (5 * $i)
    }
    throw "API call failed after retries: $Uri"
}

# ---- 3. register this machine's dedicated key (idempotent, matched by content) ----
$pubPath = "$env:USERPROFILE\.ssh\github_beautyinapple.pub"
if (-not (Test-Path $pubPath)) { throw "missing $pubPath; run: ssh-keygen -t ed25519 -f $pubPath -N ''" }
$pub = (Get-Content $pubPath -Raw).Trim()
$fp = ((ssh-keygen -lf $pubPath | Out-String) -replace '^(\S+ \S+) .*', '$1').Trim()
$existingRaw = Invoke-GitHubWithRetry 'https://api.github.com/user/keys'
$existing = @($existingRaw) | Where-Object { $null -ne $_ -and $null -ne $_.key }
# GitHub stores keys without the trailing comment, so compare type+material only.
$pubCore = ($pub -split ' ')[0..1] -join ' '
$already = @($existing | Where-Object { ($_.key.Trim() -split ' ')[0..1] -join ' ' } | Where-Object { $_ -eq $pubCore }).Count -gt 0
if (-not $already) {
    try {
        Invoke-GitHubWithRetry 'https://api.github.com/user/keys' 'POST' @{ key = $pub; title = 'beautyinapple-win' } | Out-Null
        "api: registered key $fp"
    } catch {
        if ($_ -match 'HTTP 422') { "api: key already registered (422), continuing" } else { throw }
    }
} else { "api: key $fp already registered, skipped" }

# ---- 4. create the private repo (reuse when it already exists) ----
$owner = (Invoke-GitHubWithRetry 'https://api.github.com/user').login
try {
    $repo = Invoke-GitHubWithRetry "https://api.github.com/repos/$owner/$RepoName"
    "api: repo $($repo.full_name) already exists, reusing"
} catch {
    $repo = Invoke-GitHubWithRetry 'https://api.github.com/user/repos' 'POST' @{
        name = $RepoName; private = $true; has_issues = $true; auto_init = $false
    }
    "api: created private repo $($repo.full_name)"
}

# ---- 5. push main over SSH ----
Set-Location $repoRoot
$remoteUrl = "git@github.com:$owner/$RepoName.git"
# Native stderr under EAP=Stop becomes a terminating error; wrap each git call.
function Get-GitRemoteUrl {
    try { ((git remote get-url origin 2>&1) | Out-String).Trim() } catch { '' }
}
function Set-GitRemote($url) {
    try { git remote remove origin 2>&1 | Out-Null } catch { }
    git remote add origin $url 2>&1 | ForEach-Object { "$_" }
}
$cur = Get-GitRemoteUrl
if ($cur -ne $remoteUrl) { Set-GitRemote $remoteUrl }
"git: origin = $remoteUrl"
$sshProbe = try { ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 } catch { $_.Exception.Message }
"ssh: $sshProbe"
# git writes progress on stderr; let it stream without EAP=Stop turning it into a halt.
$ErrorActionPreference = 'Continue'
git push -u origin main 2>&1 | ForEach-Object { "push: $_" }
$pushExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($pushExit -ne 0) { throw "git push failed (exit $pushExit)" }

# ---- 6. CI status ----
Start-Sleep -Seconds 8
$runs = Invoke-GitHubWithRetry "https://api.github.com/repos/$owner/$RepoName/actions/runs"
"ci: workflow runs = $($runs.total_count) (Actions registration may lag a few seconds)"
""
"Track CI at: https://github.com/$owner/$RepoName/actions"
"Or re-run this script; step 6 prints the current runs summary."
