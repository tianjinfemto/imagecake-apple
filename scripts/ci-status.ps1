# One-shot CI status snapshot for tianjinfemto/imagecake-apple (reads token from Windows credential store, never prints it).
$ErrorActionPreference = 'Stop'
$out = "protocol=https`nhost=github.com`n" -replace '`n', "`n" |
    & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
$token = ($out | Select-String '^password=').ToString().Substring(9)
$hdr = Join-Path $env:TEMP 'ci-header.txt'
Set-Content -Path $hdr -Value @("header = `"Authorization: token $token`"", 'header = "Accept: application/vnd.github+json"') -Encoding ASCII
$json = Join-Path $env:TEMP 'ci-runs.json'
curl.exe -sS --config $hdr --max-time 40 -o $json 'https://api.github.com/repos/tianjinfemto/imagecake-apple/actions/runs?per_page=10'
$runs = (Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json).workflow_runs
foreach ($r in $runs) {
    "{0}  sha={1}  {2,-12} {3}" -f $r.id, $r.head_sha.Substring(0, 7), $r.status, $r.conclusion
}
$latest = $runs | Select-Object -First 1
if ($latest.status -eq 'completed') {
    '--- failed jobs ---'
    $jobsFile = Join-Path $env:TEMP 'ci-jobs.json'
    curl.exe -sS --config $hdr --max-time 40 -o $jobsFile $latest.jobs_url
    $jobs = (Get-Content $jobsFile -Raw -Encoding UTF8 | ConvertFrom-Json).jobs
    foreach ($j in $jobs) { "  {0,-28} {1}" -f $j.name, $j.conclusion }
}
Remove-Item $hdr -ErrorAction SilentlyContinue
