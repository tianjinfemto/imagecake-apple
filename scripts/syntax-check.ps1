$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\github-bootstrap.ps1", [ref]$null, [ref]$errs)
if ($errs.Count -eq 0) { 'SYNTAX OK' } else { $errs | ForEach-Object { "{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message } }
