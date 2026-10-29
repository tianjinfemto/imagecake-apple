# Poll the newest CI run until it finishes (or the wait budget runs out), then print job results.
# Usage: powershell -File scripts/ci-wait.ps1 [-TimeoutMinutes 25]
$ErrorActionPreference = 'Stop'
$timeoutMin = 25
if ($Args.Count -ge 1) { $timeoutMin = [int]$Args[0] }
$out = "protocol=https`nhost=github.com`n" -replace '`n', "`n" |
    & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
$token = ($out | Select-String '^password=').ToString().Substring(9)
$hdr = Join-Path $env:TEMP 'ci-header.txt'
Set-Content -Path $hdr -Value @("header = `"Authorization: token $token`"", 'header = "Accept: application/vnd.github+json"') -Encoding ASCII
$json = Join-Path $env:TEMP 'ci-wait.json'
$deadline = (Get-Date).AddMinutes($timeoutMin)

while ((Get-Date) -lt $deadline) {
    curl.exe -sS --config $hdr --max-time 40 -o $json 'https://api.github.com/repos/tianjinfemto/imagecake-apple/actions/runs?per_page=1'
    $run = (Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json).workflow_runs | Select-Object -First 1
    $stamp = (Get-Date).ToString('HH:mm:ss')
    if ($run.status -eq 'completed') {
        "[$stamp] run $($run.id) sha=$($run.head_sha.Substring(0,7)) => $($run.conclusion)"
        $jobsFile = Join-Path $env:TEMP 'ci-wait-jobs.json'
        curl.exe -sS --config $hdr --max-time 40 -o $jobsFile $run.jobs_url
        $jobs = (Get-Content $jobsFile -Raw -Encoding UTF8 | ConvertFrom-Json).jobs
        foreach ($j in $jobs) {
            "  {0,-30} {1}" -f $j.name, $j.conclusion
            foreach ($s in $j.steps) {
                if ($s.conclusion -eq 'failure') { "      FAILED STEP: $($s.name)" }
            }
        }
        Remove-Item $hdr -ErrorAction SilentlyContinue
        exit 0
    }
    "[$stamp] run $($run.id) sha=$($run.head_sha.Substring(0,7)) $($run.status) ... ($([math]::Round(($deadline - (Get-Date)).TotalMinutes,1)) min left)"
    Start-Sleep -Seconds 60
}
'still running after wait budget; check again later'
Remove-Item $hdr -ErrorAction SilentlyContinue
exit 1
