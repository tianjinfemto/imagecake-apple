# Dump failed step names + the failing build log tail for one CI run.
$ErrorActionPreference = 'Stop'
$RunId = if ($Args.Count -ge 1) { $Args[0] } else { '40804863762' }
$out = "protocol=https`nhost=github.com`n" -replace '`n', "`n" |
    & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
$token = ($out | Select-String '^password=').ToString().Substring(9)
$hdr = Join-Path $env:TEMP 'ci-header.txt'
Set-Content -Path $hdr -Value @("header = `"Authorization: token $token`"", 'header = "Accept: application/vnd.github+json"') -Encoding ASCII

$jobsFile = Join-Path $env:TEMP 'ci-jobs.json'
curl.exe -sS --config $hdr --max-time 40 -o $jobsFile "https://api.github.com/repos/tianjinfemto/imagecake-apple/actions/runs/$RunId/jobs"
$jobs = (Get-Content $jobsFile -Raw -Encoding UTF8 | ConvertFrom-Json).jobs
foreach ($j in $jobs) {
    "### JOB: $($j.name)  ($($j.conclusion))"
    foreach ($s in $j.steps) {
        if ($s.conclusion -eq 'failure') { "  FAILED STEP: $($s.name)" }
    }
}

# Download the whole-run log archive and show error lines of the failing jobs.
$logZip = Join-Path $env:TEMP "ci-log-$RunId.zip"
curl.exe -sSL --config $hdr --max-time 120 -o $logZip "https://api.github.com/repos/tianjinfemto/imagecake-apple/actions/runs/$RunId/logs"
$dst = Join-Path $env:TEMP "ci-log-$RunId"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Expand-Archive -Path $logZip -DestinationPath $dst -Force
'--- log files ---'
Get-ChildItem $dst -Recurse -File | ForEach-Object { $_.FullName.Substring($dst.Length + 1) + "  (" + $_.Length + " bytes)" }
Remove-Item $hdr -ErrorAction SilentlyContinue
