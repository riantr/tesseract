$ErrorActionPreference = 'Stop'
# Derived from the script's own location rather than hardcoded, so renaming the
# project directory does not silently point the scan at the wrong tree.
$root = Split-Path $PSScriptRoot -Parent
$out  = "$root/_verify"

function Invoke-Scan([string]$version, [string]$dest) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'moonx'
  $psi.Arguments = "riantr/moonbit_static_analysis@$version ."
  $psi.WorkingDirectory = $root
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  $enc = New-Object System.Text.UTF8Encoding($false)
  # Normalise the absolute root so the capture is reproducible on another
  # machine and the fixture can be committed.
  $norm = $stdout.Replace($root, '<ROOT>')
  [System.IO.File]::WriteAllText($dest, $norm, $enc)
  Write-Output "--- $version --- exit=$($p.ExitCode) bytes=$($norm.Length)"
  foreach ($l in ($norm -split "`n")) {
    $s = $l.TrimEnd("`r")
    if ($s -match '^(SUMMARY|PARSED|TARGET|SCANNED|NOTPARSE)') { Write-Output ($s -replace "`t", ' <TAB> ') }
  }
  if ($stderr.Trim().Length -gt 0) { Write-Output ("stderr: " + $stderr.Trim()) }
}

Invoke-Scan '0.4.0' "$out/scan_040.tsv"
Invoke-Scan '0.3.5' "$out/scan_035.tsv"