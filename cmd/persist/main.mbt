///|
/// The same store as `cmd/main`, with a `.db` file behind it.
///
/// This is a separate binary rather than a flag on `cmd/main` because
/// `moonbit-community/sqlite3` only builds for `native` and `wasm`. Adding it
/// to `cmd/main` would drop that package from `js` and `wasm-gc`, and
/// `src/tesseract` would still have to stay dependency-free for the same
/// reason. Nothing in the core library or the original CLI is touched.
///
/// Persistence is a snapshot, not a mirror: the lattice lives in memory for the
/// life of the process and reaches the file when `.save` asks it to. Closing
/// without saving loses whatever was written since the last one.
///
/// `.open` restores what the file stored, timestamps included — each cell is
/// reinserted with its own stamp rather than a fresh one from this process's log
/// counter. The log's own numbering does not carry over, so stamps made after an
/// `.open` continue from this process, not from where the saved file stopped.
///
/// ```sh
/// moon run cmd/persist --target native -- .open sudoku.db \
///   "INSERT INTO tesseract (key,value,digit) VALUES ('a','{\"n\":1}',1) AT 1;" \
///   .save .status
/// ```

///|;

///|
/// stdout carries everything the commands report; stderr carries the banner and
/// failures only.
///
/// `cmd/main` splits its streams because `.export` writes a document that gets
/// redirected into a file. Nothing here does that — a persistence session is
/// read by a person — so the same split would only make a successful run print
/// nothing at all.
struct Cli {
  mut quit : Bool
  mut opened : String
  mut saved : Bool
}

///|
let cli : Cli = { quit: false, opened: "", saved: false, }

///|
fn out(text : String) -> Unit {
  println(text)
}

///|
fn warn(text : String) -> Unit {
  eprintln(text)
}

///|
/// Runs one command, turning a SQLite failure into a message.
///
/// A `SqliteError` that reaches `main` is not a report: it aborts the process
/// with a PanicError and a native backtrace. "no such file" deserves a line of
/// text, not a crash dump.
fn safely(label : String, body : () -> Unit raise) -> Unit {
  body() catch {
    // `SqliteError` is an abstract error type, so it has no constructor pattern
    // for `catch` to match on; the message is read through a `match` instead.
    e =>
      match e {
        @sqlite3.SqliteError(msg~, ..) => warn(label + " failed: " + msg)
        _ => warn(label + " failed: " + e.to_string())
      }
  }
}

///|
fn print_help() -> Unit {
  out("")
  out("usage: moon run cmd/persist --target native -- <sql-or-command>...")
  out("")
  out("commands:")
  out("  .open <path>           replace the store with the contents of <path>")
  out(
    "  .save [path]           write the store to <path>, or to the last .open",
  )
  out("  .status                lattice occupancy and cursor")
  out("  .verify                check the digits against the sudoku rules")
  out("  .help                  this list")
  out("")
  out("anything else is executed as SQL by the same parser cmd/main uses.")
  out("the store is in memory between .open and .save; nothing is mirrored.")
}

///|
fn print_status(db : @tesseract.Tesseract) -> Unit {
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  let s = @tesseract.Tesseract::status(db)
  let here = @tesseract.coords_of(lat, s.current_position).unwrap()
  out("database: " + s.db_name)
  out(
    "lattice : " +
    @tesseract.lattice_shape_text(lat) +
    " = " +
    @tesseract.sudoku_line_count(lat).to_string() +
    " lines, " +
    (@tesseract.DIM * lat.side).to_string() +
    " slabs",
  )
  out("records : " + s.current_count.to_string())
  out("digits  : " + s.digit_count.to_string())
  out(
    "cursor  : " +
    s.current_position.to_string() +
    " " +
    @tesseract.format_coords(here),
  )
  if cli.opened != "" {
    out("file    : " + cli.opened)
  }
}

///|
/// `.verify` — the same check `cmd/main` runs, over the digits in the store.
fn verify(db : @tesseract.Tesseract) -> Unit {
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  let all = @tesseract.Tesseract::select(
    db,
    "",
    "",
    None,
    @tesseract.no_filter(),
    None,
  )
  let digits = @tesseract.empty_digits(lat)
  for row in all.data {
    if row.digit != @tesseract.NO_DIGIT {
      @tesseract.set_digit(lat, digits, row.position, row.digit)
    }
  }
  let lines = @tesseract.line_violations(lat, digits)
  let slabs = @tesseract.slab_violations(lat, digits)
  out("line violations : " + lines.length().to_string())
  out("slab imbalances : " + slabs.length().to_string())
}

///|
/// Everything after the first word, trimmed.
fn argument(line : String, keyword : String) -> String {
  @tesseract.trim_ws(@tesseract.slice(line, keyword.length(), line.length()))
}

///|
fn handle_dot(db : @tesseract.Tesseract, line : String) -> Bool {
  if line == ".help" || line == "-h" || line == "--help" {
    print_help()
    return true
  }
  if line == ".status" {
    print_status(db)
    return true
  }
  if line == ".verify" {
    verify(db)
    return true
  }
  if @tesseract.starts_with(line, ".open ") {
    let path = argument(line, ".open")
    safely(".open", fn() raise {
      let report = @tesseract_sqlite.load(path, db)
      cli.opened = path
      out(
        "opened " +
        path +
        ": " +
        report.loaded.to_string() +
        " record(s), " +
        report.rejected.to_string() +
        " rejected, cursor " +
        report.cursor.to_string(),
      )
    })
    return true
  }
  if @tesseract.starts_with(line, ".save") {
    let wanted = argument(line, ".save")
    let path = if wanted == "" { cli.opened } else { wanted }
    if path == "" {
      warn(".save needs a path, or an .open to take it from")
    } else {
      safely(".save", fn() raise {
        let written = @tesseract_sqlite.save(path, db)
        cli.saved = true
        out("saved " + written.to_string() + " record(s) to " + path)
      })
    }
    return true
  }
  if line == ".quit" || line == ".exit" {
    cli.quit = true
    return true
  }
  // Not a dot command: `false` is how `main` learns to run this as SQL.
  false
}

///|
fn main {
  let all = @env.args()
  let args = if all.length() > 0 { all[1:] } else { all }
  warn("Tesseract 4D - persistence CLI (native + wasm)")
  if args.length() == 0 {
    print_help()
    return
  }
  let logger = @tesseract.new_logger("tesseract")
  // Same reasoning as `cmd/main`, and it matters more here: `.save` writes the
  // timestamps it was given into the `.db` and `.open` reads them back, so a
  // persisted file full of `#7` counters is not a timestamp.
  @tesseract.TesseractLogger::set_clock(logger, @tesseract.system_clock())
  let db = @tesseract.new_db("tesseract", @tesseract.default_lattice(), logger)
  @tesseract.TesseractLogger::set_echo(
    @tesseract.Tesseract::get_logger(db),
    true,
  )
  let mut i = 0
  while i < args.length() {
    // A command and its argument arrive as two argv entries under ordinary
    // shell word-splitting: `-- .open sudoku.db` is `.open` and `sudoku.db`.
    // A bare `.open` matches nothing in `handle_dot` and falls through to the
    // SQL parser, which reports "Unsupported SQL statement: .open" and leaves
    // `cli.opened` empty so the `.save` that follows has no file to write to.
    //
    // `.save`'s argument is optional, so an entry that looks like another
    // command is left alone - otherwise a trailing bare `.save` would swallow
    // the `.status` after it and write to a file called ".status".
    let mut arg = args[i]
    if (arg == ".open" || arg == ".save") &&
      i + 1 < args.length() &&
      args[i + 1].length() > 0 &&
      args[i + 1].at(0) != '.' {
      arg = arg + " " + args[i + 1]
      i = i + 1
    }
    if !cli.quit {
      if !handle_dot(db, arg) {
        out(@tesseract.format_response(@tesseract.execute(db, arg)))
      }
    }
    i = i + 1
  }
  // A session that opened a file and never wrote one back loses everything it
  // did. Saying so is the whole reason `.save` is a separate verb rather than
  // something that happens on exit.
  if cli.opened != "" && !cli.saved {
    out("note: nothing was saved — the store was in memory only")
  }
}
