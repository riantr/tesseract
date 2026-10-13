# Discriminating-power check: each perturbation is a real bug this parser could
# plausibly have (several of them were in fact bugs during this work). A
# perturbation that stays green means the test suite cannot see it, and the
# honest conclusion is "not covered" - not "correct".
#
# The anchor must be the complete syntactic unit being replaced and must occur
# exactly once; a count != 1 is reported as ERROR instead of being skipped,
# because "replace first match" would silently change what a later run tests.

$ErrorActionPreference = 'Stop'
$root = 'D:/src/MiniMax/Projects/tesseract/sudokudb-mbt'
$target = "$root/src/sudokudb_sa/parse.mbt"
$backup = "$root/_verify/parse.mbt.orig"
$enc = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $backup)) {
  [System.IO.File]::Copy($target, $backup)
}

$cases = @(
  @{
    name = 'header_path_as_field_2'
    why  = 'read the path as field 2 instead of the last field; on 0.4.0 FOUND/PARTIAL that stores "defects=N" as a filename'
    old  = "  let path = fields[fields.length() - 1]"
    new  = "  let path = fields[1]"
  },
  @{
    name = 'pct_keeps_trailing_percent'
    why  = 'forget to drop the % before the closing paren, the exact bug fixed above'
    old  = "        let num = @sudokudb.split(inner, `"%`")`n        pct = @sudokudb.trim_ws(num[0])"
    new  = "        pct = @sudokudb.trim_ws(inner)"
  },
  @{
    name = 'partial_files_without_trim'
    why  = 'drop the trim_ws after the semicolon; leading_count stops at the space and yields 0'
    old  = "              @sudokudb.trim_ws(@sudokudb.slice(rest, i + 1, rest.length())),"
    new  = "              @sudokudb.slice(rest, i + 1, rest.length()),"
  },
  @{
    name = 'reason_line_by_indent'
    why  = 'match the reason lines by indentation instead of by shape, the brittleness the shape test exists to avoid'
    old  = "  if line.at(0) < '0' || line.at(0) > '9' {"
    new  = "  if line.at(0) != ' ' {"
  },
  @{
    name = 'stack_lines_counted_as_findings'
    why  = 'stop skipping the "  in fn() at file:line" frames under a finding'
    old  = "    if @sudokudb.starts_with(line, `"in `") {"
    new  = "    if false {"
    expect = 'GREEN (equivalent mutant, see note)'
  }
)

$results = @()
foreach ($c in $cases) {
  [System.IO.File]::Copy($backup, $target, $true)
  $text = [System.IO.File]::ReadAllText($target, $enc)
  $n = ([regex]::Matches($text, [regex]::Escape($c.old))).Count
  if ($n -ne 1) {
    $results += [pscustomobject]@{ case = $c.name; anchor = $n; predicted = '-'; actual = 'ERROR: anchor not unique' }
    continue
  }
  $text = $text.Replace($c.old, $c.new)
  [System.IO.File]::WriteAllText($target, $text, $enc)
  $out = & moon test src/sudokudb_sa 2>&1 | Out-String
  $m = [regex]::Match($out, 'Total tests: (\d+), passed: (\d+), failed: (\d+)')
  if ($m.Success) {
    $p = [int]$m.Groups[2].Value; $f = [int]$m.Groups[3].Value
    $actual = if ($f -gt 0) { "RED ($f failed)" } else { "GREEN ($p passed)" }
  } else {
    $actual = 'BUILD-ERROR'
  }
  $results += [pscustomobject]@{ case = $c.name; anchor = $n; predicted = $c.expect; actual = $actual }
}

[System.IO.File]::Copy($backup, $target, $true)
$results | Format-Table -AutoSize | Out-String -Width 200