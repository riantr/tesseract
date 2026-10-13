///|
/// Puts a `moonbit_static_analysis` run into a SQLite database.
///
/// ```sh
/// moonx riantr/moonbit_static_analysis@0.4.0 . > scan.tsv
/// moon run cmd/sa --target native -- store scan.tsv scan.db
/// moon run cmd/sa --target native -- show scan.db
/// ```
///
/// The scan itself is run separately and read from a file rather than spawned
/// from here: `riantr/moonbit_static_analysis` is designed so the analysed
/// project neither depends on it nor is modified, and shelling out to a wasm
/// tool would need a process runtime this binary deliberately does not have.
///
/// ## How to read what it prints
///
/// The coverage comes first, on purpose. `files` is how much the analyzer
/// walked; `parsed` is how much it actually read end to end, `partial` is how
/// much it read only up to a first parse error, and everything above those two
/// lines was not looked at at all - which is where the large numbers live.
/// `withheld`, `notices` and `unreliable` all count findings the tool itself
/// says do not describe your code: `withheld` on files it could not read,
/// `notices` on constructs it declined to analyze, `unreliable` from a partial
/// read. `actionable` is the only column that describes the code.

///|
fn warn(text : String) -> Unit {
  eprintln(text)
}

///|
/// Everything the commands report goes to stdout; the banner and every
/// failure go to stderr. There is no `.export` here writing a document, so the
/// split is only to keep a failure out of a pipeline that reads stdout.
fn out(text : String) -> Unit {
  println(text)
}

///|
/// Runs one command, turning a failure into a line of text.
///
/// A `SqliteError` that reaches `main` is not a report: it aborts the process
/// with a PanicError and a native backtrace. "no such file" deserves a line of
/// text, not a crash dump. `SqliteError` is an abstract error type, so it has
/// no constructor pattern for `catch` to match on; the message is read through
/// a `match` instead.
fn safely(label : String, body : () -> Unit raise) -> Unit {
  body() catch {
    e =>
      match e {
        @sqlite3.SqliteError(msg~, ..) =>
          warn("✗ " + label + " failed: " + msg)
        _ => warn("✗ " + label + " failed: " + e.to_string())
      }
  }
}

///|
fn print_help() -> Unit {
  out("")
  out("usage: moon run cmd/sa --target native -- <command> <args>")
  out("")
  out("commands:")
  out(
    "  store <scan.tsv> <db>   parse a captured scan and add it to the database",
  )
  out("  show <db>               the newest run: coverage and counts")
  out("  runs <db>              every stored run side by side")
  out("  files <db>              the files, split by how far they were read")
  out("  unparsed <db>           why the rest could not be read")
  out("")
  out("Produce the input with:")
  out("  moonx riantr/moonbit_static_analysis@0.4.0 . > scan.tsv")
  out("")
}

///|
/// Coverage first: `parsed / files` is the number that decides how much the
/// rest is worth.
fn show(db : String) -> Unit raise {
  let run_id = match @sudokudb_sa.latest_run(db) {
    None => {
      warn("no runs in " + db)
      return
    }
    Some(v) => v
  }
  let report = match @sudokudb_sa.load(db, run_id) {
    None => {
      warn("run " + run_id.to_string() + " is not readable")
      return
    }
    Some(v) => v
  }
  out("run        : " + run_id.to_string())
  out("target     : " + report.target)
  out("root       : " + report.root)
  out("")
  out(
    "coverage   : " +
    report.parsed.to_string() +
    "/" +
    report.files.to_string() +
    " files read end to end (" +
    report.parsed_pct +
    "%), " +
    report.partial_files.to_string() +
    " read only up to a parse error",
  )
  out(
    "not read  : " +
    (report.files - report.parsed - report.partial_files).to_string() +
    " more files the analyzer did not report on",
  )
  out("")
  out(
    "actionable : " +
    report.actionable.to_string() +
    "  (the only count that describes the code)",
  )
  out(
    "notices    : " +
    report.notices.to_string() +
    "  (constructs outside the analyzed subset - not defects)",
  )
  out(
    "unreliable : " +
    report.unreliable.to_string() +
    "  (from a partial read, which the tool rates unreliable)",
  )
  out(
    "withheld   : " +
    report.withheld.to_string() +
    "  (on files the analyzer could not read - not defects)",
  )
  out("total      : " + report.total.to_string())
}

///|
fn list_files(db : String) -> Unit raise {
  let run_id = match @sudokudb_sa.latest_run(db) {
    None => {
      warn("no runs in " + db)
      return
    }
    Some(v) => v
  }
  let report = match @sudokudb_sa.load(db, run_id) {
    None => return
    Some(v) => v
  }
  // `file_results` holds every file the analyzer printed a header for, which
  // since 0.4.0 includes the PARTIAL ones. Printing them under one heading
  // would call a file "read completely" when the tool stopped at its first
  // parse error, so the two are separated here.
  let mut read_whole = 0
  let mut partial = 0
  for f in report.file_results {
    match f.outcome {
      Partial => partial = partial + 1
      _ => read_whole = read_whole + 1
    }
  }
  out("read end to end (" + read_whole.to_string() + "):")
  for f in report.file_results {
    // A pattern matches without constructing; `==` and `!=` are `Eq::equal`
    // and `Eq::not_equal`, which take the value and are refused here.
    match f.outcome {
      Partial => continue
      _ => ()
    }
    // defects + notices is what the header reported; `shown` is how many lines
    // the tool actually rendered, which is usually fewer.
    let reported = f.defects + f.notices
    let note = if reported > f.shown {
      "  (" +
      reported.to_string() +
      " reported, " +
      f.shown.to_string() +
      " rendered)"
    } else {
      ""
    }
    out("  " + f.kind + "  " + f.path + note)
  }
  out("")
  if partial == 0 {
    out("no file was read only up to a parse error")
  } else {
    out("read only up to a parse error (" + partial.to_string() + "):")
    out("  everything after that line in each of these was not read")
    for f in report.file_results {
      match f.outcome {
        Partial => ()
        _ => continue
      }
      out(
        "  " +
        f.kind +
        "  " +
        f.path +
        "  (read to line " +
        f.read_up_to.to_string() +
        ", " +
        f.not_shown.to_string() +
        " lines after it not read)",
      )
    }
  }
}

///|
fn list_unparsed(db : String) -> Unit raise {
  let run_id = match @sudokudb_sa.latest_run(db) {
    None => {
      warn("no runs in " + db)
      return
    }
    Some(v) => v
  }
  let report = match @sudokudb_sa.load(db, run_id) {
    None => return
    Some(v) => v
  }
  if report.unparsed.length() == 0 {
    out("every scanned file was understood")
    return
  }
  out("why the other files could not be read:")
  for g in report.unparsed {
    out("  " + g.count.to_string() + "x  " + g.reason)
    for e in g.examples {
      out("      e.g. " + e)
    }
  }
}

///|
/// Every stored run, oldest first.
///
/// This is the command that makes accumulating runs worth anything: a 0.3.5
/// scan and a 0.4.0 scan of the same tree belong next to each other, and
/// `show` only ever looks at the newest one. The columns are aligned rather
/// than tab-separated so the eye can compare two rows, which is the only
/// reason this command exists.
fn list_runs(db : String) -> Unit raise {
  let runs = @sudokudb_sa.list_runs(db)
  if runs.length() == 0 {
    warn("no runs in " + db)
    return
  }
  out(
    "run  files  parsed   pct    partial  actionable  notices  unreliable  withheld  total",
  )
  for r in runs {
    out(
      pad(4, r.id.to_string()) +
      pad(7, r.files.to_string()) +
      pad(8, r.parsed.to_string()) +
      pad(7, r.parsed_pct + "%") +
      pad(9, r.partial_files.to_string()) +
      pad(12, r.actionable.to_string()) +
      pad(9, r.notices.to_string()) +
      pad(12, r.unreliable.to_string()) +
      pad(10, r.withheld.to_string()) +
      pad(7, r.total.to_string()),
    )
  }
}

///|
/// Right-aligns `s` in `width` columns.
fn pad(width : Int, s : String) -> String {
  let mut out = s
  while out.length() < width {
    out = " " + out
  }
  out
}

///|
/// Parses a captured scan and adds it to the database.
///
/// Only the one check that is a *business* rule lives here - the parse either
/// yields a completed run or it does not. Reading the file and writing the
/// database raise, and `safely` turns those into a line of text with the
/// driver's own message, which is better than anything this function could
/// reconstruct: `IOError` has no `to_string` and `SqliteError` is an abstract
/// type with no constructor pattern to match.
fn store(scan_file : String, db : String) -> Unit raise {
  let text = @xfs.read_file_to_string(scan_file)
  // `parse` fails when the run produced no SUMMARY, which is the tool's own
  // failure signal - a run that could not find its target still exits 0. Storing
  // that would put a run in the database whose zero findings read like a clean
  // bill of health.
  let report = match @sudokudb_sa.parse(text) {
    Ok(v) => v
    Err(e) => {
      warn("✗ " + scan_file + " is not a completed scan")
      warn("  " + e)
      return
    }
  }
  let id = @sudokudb_sa.save(db, report)
  out("stored run " + id.to_string() + " in " + db)
  out("  files     : " + report.files.to_string())
  out(
    "  parsed    : " +
    report.parsed.to_string() +
    " (" +
    report.parsed_pct +
    "%)",
  )
  out(
    "  partial   : " +
    report.partial_files.to_string() +
    " (stopped at first parse error)",
  )
  out("  actionable: " + report.actionable.to_string())
  out("  notices   : " + report.notices.to_string() + " (not defects)")
  out("  unreliable: " + report.unreliable.to_string() + " (not defects)")
  out("  withheld  : " + report.withheld.to_string() + " (not defects)")
}

///|
fn main {
  let all = @env.args()
  let args = if all.length() > 0 { all[1:] } else { all }
  warn("SudokuDB - static analysis store (native + wasm)")
  if args.length() == 0 {
    print_help()
    return
  }
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "store" && i + 1 < args.length() {
      let scan_file = args[i + 1]
      let db = if i + 2 < args.length() { args[i + 2] } else { "scan.db" }
      i = i + 2
      safely("store", fn() raise { store(scan_file, db) })
    } else if arg == "show" && i + 1 < args.length() {
      let db = args[i + 1]
      i = i + 1
      safely("show", fn() raise { show(db) })
    } else if arg == "runs" && i + 1 < args.length() {
      let db = args[i + 1]
      i = i + 1
      safely("runs", fn() raise { list_runs(db) })
    } else if arg == "files" && i + 1 < args.length() {
      let db = args[i + 1]
      i = i + 1
      safely("files", fn() raise { list_files(db) })
    } else if arg == "unparsed" && i + 1 < args.length() {
      let db = args[i + 1]
      i = i + 1
      safely("unparsed", fn() raise { list_unparsed(db) })
    } else if arg == ".help" || arg == "-h" || arg == "--help" {
      print_help()
    } else {
      warn("unknown command: " + arg)
      print_help()
    }
    i = i + 1
  }
}
