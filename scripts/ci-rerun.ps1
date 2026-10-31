# Re-run the failed jobs of a workflow run. Use this when a run failed with NO
# failed step listed -- that means the job died in runner setup (infrastructure),
# not in the build. Same token source as ci-status.ps1 (Windows credential store,
# never printed). ASCII only: PowerShell 5.1 mangles BOM-less non-ASCII scripts.
# Usage: powershell -File scripts/ci-rerun.ps1 <runId>
$ErrorActionPreference = 'Stop'
$runId = if ($Args.Count -ge 1) { $Args[0] } else { throw 'usage: ci-rerun.ps1 <runId>' }
$out = "protocol=https`nhost=github.com`n" -replace '`n', "`n" |
    & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
$token = ($out | Select-String '^password=').ToString().Substring(9)
$hdr = Join-Path $env:TEMP 'ci-rerun-header.txt'
$body = Join-Path $env:TEMP 'ci-rerun-body.json'
Set-Content -Path $hdr -Value @("header = `"Authorization: token $token`"", 'header = "Accept: application/vnd.github+json"') -Encoding ASCII
Set-Content -Path $body -Value '{}' -Encoding ASCII
curl.exe -sS -X POST --config $hdr --max-time 40 --data "@$body" `
    "https://api.github.com/repos/tianjinfemto/imagecake-apple/actions/runs/$runId/rerun-failed-jobs"
Remove-Item $hdr, $body -ErrorAction SilentlyContinue
