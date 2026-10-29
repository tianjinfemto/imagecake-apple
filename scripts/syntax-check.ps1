# Parse-check PowerShell files without executing them (PS 5.1 mangles BOM-less UTF-8, so
# these scripts stay ASCII; a parse error here is cheaper than a failed CI minute).
# Usage: powershell -File scripts/syntax-check.ps1 [file.ps1 ...]
$targets = if ($Args.Count -ge 1) { $Args } else { @("$PSScriptRoot\github-bootstrap.ps1", "$PSScriptRoot\make-app-icon.ps1", "$PSScriptRoot\ci-status.ps1", "$PSScriptRoot\ci-failure-detail.ps1") }
$bad = 0
foreach ($f in $targets) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    $nonAscii = (Get-Content $f -Raw -Encoding UTF8) -replace '[^\x00-\x7F]', ''
    $drift = if ($nonAscii.Length -ne (Get-Content $f -Raw).Length) { '  [HAS NON-ASCII]' } else { '' }
    if ($errs.Count -eq 0) { "OK    $(Split-Path $f -Leaf)$drift" }
    else {
        $bad++
        "FAIL  $(Split-Path $f -Leaf)"
        $errs | ForEach-Object { "        line $($_.Extent.StartLineNumber): $($_.Message)" }
    }
}
exit $bad
