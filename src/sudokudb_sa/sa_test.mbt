///|
/// Parsing the analyzer's output, and putting the result in a database.
///
/// `testdata_scan.tsv` is a real run of
/// `moonx riantr/moonbit_static_analysis@0.4.0` over this project, captured
/// verbatim except that the machine-specific root has been replaced with
/// `<ROOT>` so the fixture travels. Refresh it by re-running the scan and
/// re-normalising; the pinned counts at the bottom are what to update then.
///
/// The point of the fixture is that the numbers in it were produced by the
/// tool, not chosen by the test. A synthetic fixture would only prove the
/// parser agrees with a format invented next to it.

///|
fn scratch(name : String) -> String {
  "sudokudb_sa_test_" + name + ".db"
}

///|
fn remove(path : String) -> Unit {
  @xfs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// The captured scan, read from beside this file.
///
/// `moon test` runs a package's tests with the **project root** as the working
/// directory, not the package directory, so the path is rooted there.
fn real_scan() -> String raise {
  @xfs.read_file_to_string("src/sudokudb_sa/testdata_scan.tsv")
}

///|
/// A report with a partial file and two defects, built without a database.
fn sample() -> @sudokudb_sa.ScanReport {
  @sudokudb_sa.ScanReport::new(
    "/tmp/demo",
    "/tmp/demo",
    3,
    2,
    "66.7",
    1,
    2,
    3,
    4,
    5,
    14,
    [
      @sudokudb_sa.FileResult::new(
        ".mbti",
        "/tmp/demo/a.mbti",
        @sudokudb_sa.FileOutcome::clean(),
        0,
        0,
        0,
        0,
        0,
      ),
      @sudokudb_sa.FileResult::new(
        ".mbt",
        "/tmp/demo/b.mbt",
        @sudokudb_sa.FileOutcome::found(),
        2,
        1,
        2,
        0,
        0,
      ),
      @sudokudb_sa.FileResult::new(
        ".mbt",
        "/tmp/demo/c.mbt",
        @sudokudb_sa.FileOutcome::partial(),
        0,
        2,
        1,
        45,
        145,
      ),
    ],
    [
      @sudokudb_sa.Finding::new(
        "/tmp/demo/b.mbt", 12, 3, "error", "UndefinedName", "walk+types", "unknown name `nope`",
      ),
      @sudokudb_sa.Finding::new(
        "/tmp/demo/c.mbt", 21, 1, "error", "ParseError", "structural", "const declaration is outside the analyzed subset",
      ),
    ],
    [
      @sudokudb_sa.UnparsedGroup::new("unexpected token", 2, ["/tmp/demo/d.mbt"]),
    ],
    [
      @sudokudb_sa.ByKind::new(".mbt", 2, 1, 2, 3),
      @sudokudb_sa.ByKind::new(".mbti", 1, 1, 0, 0),
    ],
  )
}

///|
test "a real 0.4.0 scan parses into the counts the tool printed" {
  let report = match @sudokudb_sa.parse(real_scan()) {
    Ok(v) => v
    Err(e) => abort("the captured scan did not parse: " + e)
  }
  assert_eq(report.files, 39)
  assert_eq(report.parsed, 12)
  // 0.4.0 appends `); 27 more read only up to their first parse error` to this
  // line. A parser that kept a fixed number of characters off the end stored
  // the whole clause as the percentage, which is a string no reader checks.
  assert_eq(report.parsed_pct, "30.7")
  assert_eq(report.partial_files, 27)
  assert_eq(report.target, "<ROOT>")
  assert_eq(report.root, "<ROOT>")
  assert_eq(report.actionable, 4)
  assert_eq(report.notices, 67)
  assert_eq(report.unreliable, 5122)
  assert_eq(report.withheld, 1487)
  assert_eq(report.total, 5193)
  // 0.4.0 prints `(actionable+notices+unreliable+withheld = total)` in its own
  // SUMMARY, and on this run it does not hold: 4 + 67 + 5122 + 1487 = 6680,
  // not 5193. The identity that does hold is the same sum *without*
  // `withheld`, so `total` excludes the findings on the 27 files the analyzer
  // could not read, while `withheld` is reported alongside it.
  //
  // This is the tool's arithmetic, not this parser's, and it is pinned rather
  // than corrected in code: if a later 0.4.x starts including `withheld` in
  // `total`, this assertion goes red and the change is looked at on purpose.
  assert_eq(
    report.actionable + report.notices + report.unreliable,
    report.total,
  )
  assert_eq(
    report.actionable + report.notices + report.unreliable + report.withheld,
    report.total + report.withheld,
  )
}

///|
test "every file the scan mentions has a row, and they add up to the file count" {
  let report = match @sudokudb_sa.parse(real_scan()) {
    Ok(v) => v
    Err(e) => abort("the captured scan did not parse: " + e)
  }
  let mut read_whole = 0
  let mut partial = 0
  let mut defects = 0
  let mut notices = 0
  let mut partial_defects = 0
  for f in report.file_results {
    // `defects` and `notices` are on the header of *every* outcome, PARTIAL
    // included - a file read up to its first parse error still has findings
    // before that point. Summing only the FOUND headers reads 0, because on
    // this project all three FOUND files carry `defects=0`.
    defects = defects + f.defects
    notices = notices + f.notices
    match f.outcome {
      @sudokudb_sa.Clean => read_whole = read_whole + 1
      @sudokudb_sa.Found => read_whole = read_whole + 1
      @sudokudb_sa.Partial => {
        partial = partial + 1
        partial_defects = partial_defects + f.defects
      }
    }
  }
  // The only files the tool says it read end to end.
  assert_eq(read_whole, report.parsed)
  // Every defect and every notice is on some file header, and together they are
  // exactly the SUMMARY's `actionable` and `notices` - nothing is unaccounted
  // for and nothing is counted twice.
  assert_eq(defects, report.actionable)
  assert_eq(notices, report.notices)
  // Worth stating because it is the reason this project's number is small: all
  // four actionable defects sit on files the analyzer could only read part of.
  // The three files it read end to end and found something in carry
  // `defects=0`.
  assert_eq(partial_defects, report.actionable)
  // Nothing was truncated in this run: all 4 + 67 = 71 were rendered, one line
  // each. That is a fact about this capture, not a rule — `shown` per file is
  // what records truncation when it happens.
  assert_eq(report.findings.length(), defects + notices)
  // The 27 files the scan did not read end to end split in two, and the reason
  // lines only name one of them. NOTPARSE's own header counts 27 — which is
  // `files - parsed` — but its `<n>x <reason>` groups add up to 11, the files
  // that printed no header at all. The other 16 are the PARTIAL files: they
  // were read up to a parse error and are counted without a reason, because
  // there is no single reason to give.
  let mut no_reason = 0
  for g in report.unparsed {
    no_reason = no_reason + g.count
    assert_true(g.examples.length() > 0)
    assert_true(g.examples.length() <= 3)
  }
  assert_eq(no_reason + partial, report.files - report.parsed)
  assert_eq(report.file_results.length(), read_whole + partial)
  assert_true(partial <= report.files - report.parsed)
  assert_eq(report.parsed + report.partial_files, report.files)
}

///|
test "a PARTIAL header records how far the file was read" {
  let script = "PARTIAL\t.mbt\tdefects=0\tnotices=1\tread up to line 63, 80 after it not shown\t/tmp/x.mbt\n" +
    "15:1 - error: const declaration is outside the analyzed subset (ParseError) [structural]\n" +
    "SUMMARY\tfiles=1\tparsed=0\tactionable=0\tnotices=1\tunreliable=1\twithheld=0\ttotal=2\n"
  let report = match @sudokudb_sa.parse(script) {
    Ok(v) => v
    Err(e) => abort("a partial-file scan did not parse: " + e)
  }
  assert_eq(report.file_results.length(), 1)
  let f = report.file_results[0]
  assert_eq(f.path, "/tmp/x.mbt")
  assert_eq(f.outcome, @sudokudb_sa.FileOutcome::partial())
  assert_eq(f.notices, 1)
  assert_eq(f.read_up_to, 63)
  assert_eq(f.not_shown, 80)
  // The path is the last field. Reading field 2 as the path would have stored
  // "defects=0" as a filename - a row that looks present and points nowhere.
  assert_eq(f.kind, ".mbt")
}

///|
test "a finding line is taken apart and the stack under it is not" {
  // The message contains ": " and parentheses of its own, so the family has to
  // come off the end rather than the first match, and the `  in ...` frames
  // under it must not be mistaken for more findings.
  let script = "FOUND\t.mbt\tdefects=7\tnotices=2\t/tmp/b.mbt\n" +
    "12:3 - error: unknown name `nope` (UndefinedName) [walk+types]\n" +
    "  in main() at main.mbt:87\n" +
    "  in warn at b.mbt:25\n" +
    "20:1 - warning: value `dead` is never read (and it has: a colon) (UnusedValue) [types]\n" +
    "...  5 more in this file\n" +
    "SUMMARY\tfiles=1\tparsed=1\tactionable=7\tnotices=2\tunreliable=0\twithheld=0\ttotal=9\n"
  let report = match @sudokudb_sa.parse(script) {
    Ok(v) => v
    Err(e) => abort("a finding-bearing scan did not parse: " + e)
  }
  assert_eq(report.findings.length(), 2)
  assert_eq(report.findings[0].line, 12)
  assert_eq(report.findings[0].family, "UndefinedName")
  assert_eq(report.findings[0].lenses, "walk+types")
  assert_eq(report.findings[0].path, "/tmp/b.mbt")
  assert_eq(report.findings[1].family, "UnusedValue")
  assert_eq(
    report.findings[1].message,
    "value `dead` is never read (and it has: a colon)",
  )
  // The header said 7 defects; 2 were rendered. Both numbers are kept so the
  // stored list cannot be mistaken for the whole set - and the header's total
  // agrees with the SUMMARY's `actionable=7`, which is what ties a per-file
  // count to the run-wide one.
  assert_eq(report.file_results[0].defects, 7)
  assert_eq(report.file_results[0].notices, 2)
  assert_eq(report.file_results[0].defects, report.actionable)
  assert_eq(report.file_results[0].shown, 2)
}

///|
test "a 0.3.5 scan still parses, because the database holds both" {
  // 0.3.5 wrote a bare count where 0.4.0 writes `defects=`/`notices=`, and had
  // no PARTIAL, BYKIND, partial_files or unreliable. Refusing it would mean a
  // database that can only ever hold scans from one version.
  let script = "TARGET\t/tmp/demo\t/tmp/demo\n" +
    "SCANNED\t3 files under /tmp/demo\n" +
    "CLEAN\t.mbti\t/tmp/a.mbti\n" +
    "FOUND\t.mbt\t7\t/tmp/b.mbt\n" +
    "12:3 - error: unknown name `nope` (UndefinedName) [walk]\n" +
    "...  5 more in this file\n" +
    "PARSED\t2/3 files understood (66.7%)\n" +
    "NOTPARSE\t1 files, 9 finding(s) withheld - they measure what this analyzer does not understand\n" +
    "  1x  unexpected token\n" +
    "      e.g. /tmp/c.mbt\n" +
    "SUMMARY\tfiles=3\tparsed=2\tactionable=7\twithheld=9\ttotal=16\n"
  let report = match @sudokudb_sa.parse(script) {
    Ok(v) => v
    Err(e) => abort("a 0.3.5-shaped scan did not parse: " + e)
  }
  assert_eq(report.files, 3)
  assert_eq(report.parsed, 2)
  assert_eq(report.parsed_pct, "66.7")
  assert_eq(report.partial_files, 0)
  assert_eq(report.actionable, 7)
  // Counters 0.3.5 never printed read as 0, which is exactly what it reported.
  assert_eq(report.notices, 0)
  assert_eq(report.unreliable, 0)
  assert_eq(report.withheld, 9)
  assert_eq(report.by_kind.length(), 0)
  assert_eq(report.file_results.length(), 2)
  assert_eq(report.file_results[1].defects, 7)
  assert_eq(report.file_results[1].notices, 0)
  assert_eq(report.file_results[1].shown, 1)
  assert_eq(report.unparsed.length(), 1)
  assert_eq(report.unparsed[0].count, 1)
}

///|
test "output with no SUMMARY is a failure, not an empty clean run" {
  // The tool's own documentation: a target it cannot find still exits 0 and
  // prints only this line. Storing it would put a run in the database whose
  // zero findings read like "the scan found nothing".
  let r = @sudokudb_sa.parse("ERROR\tcannot locate source for target: /nope\n")
  assert_true(r is Err(_))
  match r {
    Err(e) => assert_true(e.contains("cannot locate source"))
    Ok(_) => assert_true(false)
  }
  assert_true(@sudokudb_sa.parse("") is Err(_))
  assert_true(@sudokudb_sa.parse("hello\n") is Err(_))
}

///|
test "a byte-order mark on the first line does not hide the TARGET" {
  let script = "\u{FEFF}TARGET\t/tmp/demo\t/tmp/demo\n" +
    "SUMMARY\tfiles=0\tparsed=0\tactionable=0\tnotices=0\tunreliable=0\twithheld=0\ttotal=0\n"
  let report = match @sudokudb_sa.parse(script) {
    Ok(v) => v
    Err(e) => abort("BOM-prefixed output did not parse: " + e)
  }
  assert_eq(report.target, "/tmp/demo")
  assert_eq(report.root, "/tmp/demo")
}

///|
test "a stored report reads back exactly as it parsed" {
  let path = scratch("roundtrip")
  remove(path)
  let want = sample()
  let id = @sudokudb_sa.save(path, want)
  assert_true(id > 0)
  let got = match @sudokudb_sa.load(path, id) {
    Some(v) => v
    None => abort("the run was not readable back")
  }
  assert_eq(got.target, want.target)
  assert_eq(got.parsed_pct, want.parsed_pct)
  assert_eq(got.partial_files, want.partial_files)
  assert_eq(got.actionable, want.actionable)
  assert_eq(got.notices, want.notices)
  assert_eq(got.unreliable, want.unreliable)
  assert_eq(got.withheld, want.withheld)
  assert_eq(got.total, want.total)
  assert_eq(got.file_results.length(), 3)
  assert_eq(got.file_results[1].outcome, @sudokudb_sa.FileOutcome::found())
  assert_eq(got.file_results[1].defects, 2)
  assert_eq(got.file_results[1].notices, 1)
  // A partial file has to come back partial, with the extent intact - that is
  // the whole reason it is a separate outcome.
  assert_eq(got.file_results[2].outcome, @sudokudb_sa.FileOutcome::partial())
  assert_eq(got.file_results[2].read_up_to, 45)
  assert_eq(got.file_results[2].not_shown, 145)
  assert_eq(got.by_kind.length(), 2)
  assert_eq(got.by_kind[0].kind, ".mbt")
  assert_eq(got.by_kind[0].notices, 3)
  assert_eq(got.unparsed[0].examples[0], "/tmp/demo/d.mbt")
  remove(path)
}

///|
test "the real 0.4.0 scan survives a trip through the database" {
  let path = scratch("realscan")
  remove(path)
  let want = match @sudokudb_sa.parse(real_scan()) {
    Ok(v) => v
    Err(e) => abort("the captured scan did not parse: " + e)
  }
  let id = @sudokudb_sa.save(path, want)
  let got = match @sudokudb_sa.load(path, id) {
    Some(v) => v
    None => abort("the run was not readable back")
  }
  assert_eq(got.files, 39)
  assert_eq(got.parsed, 12)
  assert_eq(got.parsed_pct, "30.7")
  assert_eq(got.partial_files, 27)
  assert_eq(got.actionable, 4)
  assert_eq(got.notices, 67)
  assert_eq(got.unreliable, 5122)
  assert_eq(got.withheld, 1487)
  assert_eq(got.file_results.length(), want.file_results.length())
  assert_eq(got.by_kind.length(), want.by_kind.length())
  for i = 0; i < want.by_kind.length(); i = i + 1 {
    assert_eq(got.by_kind[i].kind, want.by_kind[i].kind)
    assert_eq(got.by_kind[i].files, want.by_kind[i].files)
    assert_eq(got.by_kind[i].defects, want.by_kind[i].defects)
  }
  assert_eq(got.unparsed.length(), want.unparsed.length())
  for i = 0; i < want.unparsed.length(); i = i + 1 {
    assert_eq(got.unparsed[i].reason, want.unparsed[i].reason)
    assert_eq(got.unparsed[i].count, want.unparsed[i].count)
    assert_eq(
      got.unparsed[i].examples.length(),
      want.unparsed[i].examples.length(),
    )
  }
  remove(path)
}

///|
test "runs accumulate and each keeps its own rows" {
  let path = scratch("history")
  remove(path)
  let first = @sudokudb_sa.save(path, sample())
  let second = match
    @sudokudb_sa.parse(
      "SUMMARY\tfiles=9\tparsed=1\tactionable=3\tnotices=1\tunreliable=2\twithheld=100\ttotal=106\n",
    ) {
    Ok(v) => @sudokudb_sa.save(path, v)
    Err(e) => abort("a bare summary did not parse: " + e)
  }
  assert_true(second > first)
  match @sudokudb_sa.latest_run(path) {
    None => assert_true(false)
    Some(latest) => {
      assert_eq(latest, second)
      let got = match @sudokudb_sa.load(path, latest) {
        Some(v) => v
        None => abort("the newest run was not readable")
      }
      assert_eq(got.files, 9)
      // The earlier run keeps its own file rows rather than being overwritten.
      let older = match @sudokudb_sa.load(path, first) {
        Some(v) => v
        None => abort("the earlier run was not readable")
      }
      assert_eq(older.file_results.length(), 3)
      assert_eq(older.by_kind.length(), 2)
      // And both are listable side by side, oldest first, with their own
      // numbers - the reason runs accumulate rather than being replaced. The
      // counts are compared against the runs themselves rather than against
      // literals, so this stays a statement about `list_runs` and not about
      // the sample's numbers.
      let runs = @sudokudb_sa.list_runs(path)
      assert_eq(runs.length(), 2)
      assert_eq(runs[0].id, first)
      assert_eq(runs[1].id, latest)
      assert_eq(runs[0].id < runs[1].id, true)
      assert_eq(runs[0].files, older.files)
      assert_eq(runs[0].actionable, older.actionable)
      assert_eq(runs[0].withheld, older.withheld)
      assert_eq(runs[1].files, got.files)
      assert_eq(runs[1].actionable, got.actionable)
      assert_eq(runs[1].withheld, got.withheld)
    }
  }
  remove(path)
}
