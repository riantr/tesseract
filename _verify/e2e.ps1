$ErrorActionPreference = 'Stop'
$root = 'D:/src/MiniMax/Projects/tesseract/sudokudb-mbt'

function Invoke-Sa([string[]]$saArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'moon'
  $a = @('run', 'cmd/sa', '--target', 'native', '--') + $saArgs
  $psi.Arguments = ($a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.WorkingDirectory = $root
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  Write-Output ("moon " + $psi.Arguments + "   [exit " + $p.ExitCode + "]")
  Write-Output $stdout.TrimEnd()
  $e = ($stderr -split "`n" | Where-Object { $_ -notmatch 'SudokuDB - static analysis store' -and $_.Trim().Length -gt 0 })
  if ($e) { Write-Output ("  stderr: " + ($e -join ' | ')) }
  Write-Output ""
}

$db = "$root/_verify/two.db"
if (Test-Path $db) { Remove-Item $db -Force }

Invoke-Sa @('store', '_verify/scan_040.tsv', '_verify/two.db')
Invoke-Sa @('store', '_verify/scan_035.tsv', '_verify/two.db')
Write-Output "===== show (newest run) ====="
Invoke-Sa @('show', '_verify/two.db')
Write-Output "===== unparsed ====="
Invoke-Sa @('unparsed', '_verify/two.db')
Write-Output "===== files ====="
Invoke-Sa @('files', '_verify/two.db')