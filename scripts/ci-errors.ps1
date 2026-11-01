# ci-errors.ps1 - print the compile errors and the failed test cases of a CI run.
#
# Why this exists instead of reading the Actions page: the run log is a zip of
# per-step files whose names contain "·" and spaces, which PowerShell 5.1 mangles
# when you glob them; and `xcodebuild test` interleaves three jobs' output.
# This script picks the macOS job (its `xcodebuild test` output carries the whole
# program's compile diagnostics, and `-quiet` suppresses success noise), then
# prints unique `error:` lines plus any `Test Case ... failed` / assertion lines.
#
# Usage:
#   powershell -File scripts/ci-errors.ps1                      # latest run
#   powershell -File scripts/ci-errors.ps1 41268862547          # specific run
# Exit code mirrors the run conclusion so it composes in a loop.
param(
    [string]$RunId = "",
    [string]$Repo = "tianjinfemto/imagecake-apple",
    [switch]$IncludeNotes                          # also print warnings
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$out = "protocol=https`nhost=github.com`n" | & 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe' get 2>&1
$token = ($out | Select-String '^password=').ToString().Substring(9)
$hdr = Join-Path $env:TEMP "ci-errors-hdr-$PID.txt"
Set-Content -Path $hdr -Value @(
    "header = `"Authorization: token $token`"",
    'header = "Accept: application/vnd.github+json"'
) -Encoding ASCII
try {
    $base = "https://api.github.com/repos/$Repo"
    if (-not $RunId) {
        $list = Join-Path $env:TEMP "ci-errors-list-$PID.json"
        curl.exe -sS --config $hdr -o $list --max-time 40 "$base/actions/runs?per_page=1" | Out-Null
        $RunId = ((Get-Content $list -Raw -Encoding UTF8 | ConvertFrom-Json).workflow_runs[0]).id
        Remove-Item $list -ErrorAction SilentlyContinue
    }
    $meta = Join-Path $env:TEMP "ci-errors-meta-$PID.json"
    curl.exe -sS --config $hdr -o $meta --max-time 40 "$base/actions/runs/$RunId" | Out-Null
    $run = Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json
    "run=$RunId sha=$($run.head_sha.Substring(0,7)) $($run.status) $($run.conclusion)"

    $zip = Join-Path $env:TEMP "ci-errors-$RunId.zip"
    curl.exe -sSL --config $hdr -o $zip --max-time 240 "$base/actions/runs/$RunId/logs" | Out-Null
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 1000) {
        "no logs available (run probably never got a runner - see ci-rerun.ps1 header)"
        exit 2
    }
    $dst = Join-Path $env:TEMP "ci-errors-$RunId"
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dst -Force

    # The macOS job's test step carries the full program's diagnostics.
    $file = Get-ChildItem $dst -Recurse -File | Where-Object { $_.Name -match 'Test on macOS' } | Select-Object -First 1
    if (-not $file) {
        $file = Get-ChildItem $dst -Recurse -File | Sort-Object Length -Descending | Select-Object -First 1
    }
    "logfile=$($file.Name) ($([math]::Round($file.Length/1024)) KB)"
    $lines = Get-Content $file.FullName

    $errs = $lines | Select-String -Pattern 'error:' | ForEach-Object {
        ($_.Line -replace '^.*Z ', '' -replace '/Users/runner/work/[^/]*/[^/]*/', '')
    } | Select-Object -Unique
    if ($errs) {
        "--- compile errors (" + $errs.Count + ") ---"
        $errs | Select-Object -First 40
    } else {
        "--- no compile errors ---"
    }

    $failed = $lines | Select-String -Pattern "Test Case .*'(failed|passed)'" | ForEach-Object { $_.Line -replace '^.*Z ', '' }
    if ($failed) {
        "--- failed test cases ---"
        $failed | Where-Object { $_ -match 'failed' } | Select-Object -Unique -First 40
        $sum = $lines | Select-String -Pattern 'Executed \d+ tests' | ForEach-Object { $_.Line -replace '^.*Z ', '' } | Select-Object -Unique
        if ($sum) { "--- totals ---"; $sum | Select-Object -First 6 }
        $asserts = $lines | Select-String -Pattern 'XCTAssert\w+ failed' | ForEach-Object {
            ($_.Line -replace '^.*Z ', '' -replace '/Users/runner/work/[^/]*/[^/]*/', '')
        } | Select-Object -Unique -First 25
        if ($asserts) { "--- assertion messages ---"; $asserts }
    }
    if ($IncludeNotes) {
        $warns = $lines | Select-String -Pattern 'warning:' | ForEach-Object {
            ($_.Line -replace '^.*Z ', '' -replace '/Users/runner/work/[^/]*/[^/]*/', '')
        } | Select-Object -Unique -First 20
        if ($warns) { "--- warnings ---"; $warns }
    }
    exit $(if ($run.conclusion -eq 'success') { 0 } else { 1 })
} finally {
    Remove-Item $hdr -ErrorAction SilentlyContinue
}
