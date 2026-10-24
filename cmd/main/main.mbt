///|
/// Tesseract 4D — command line front end.
///
/// The C# original was an Avalonia desktop app. MoonBit has no comparable GUI
/// toolkit, and this toolchain's core library exposes neither a stdin reader
/// nor file I/O, so the front end is a **one-shot program driven by its
/// arguments**: each argument is either a SQL statement or a `.command`, they
/// run in order against one shared database, and results go to stdout.
///
/// ```sh
/// moon run cmd/main -- .status
/// moon run cmd/main -- .demo
/// moon run cmd/main -- "INSERT INTO tesseract (key,value) VALUES ('a','1') AT 5;" "SELECT * FROM tesseract;"
/// moon run cmd/main -- .solve .verify
/// moon run cmd/main -- .export tsr > dump.tsr
/// ```
///
/// `--side N` chooses how many cells each of the four axes has. The default is 3,
/// the 81-cell lattice every existing `.tsr` and `.db` file was written under, so
/// an invocation without the flag behaves exactly as it always has:
///
/// ```sh
/// moon run cmd/main -- --side 4 .status      # 256 cells, digits 1..4
/// moon run cmd/main -- --side 4 .solve .verify
/// ```
///
/// The upper bound is 215, not the number the arithmetic alone would allow:
/// `Array` is indexed by `Int`, which is 32-bit on this toolchain, so `side^4`
/// cells have to stay addressable. `lattice_of` refuses anything larger and says
/// so rather than truncating.
///
/// A REPL is a one-line shell loop over the same commands:
///
/// ```sh
/// while read -r line; do moon run cmd/main -- "$line"; done
/// ```

///|
/// CLI-wide state: which stream chatter goes to, and whether a `.quit` was
/// asked for.
struct Cli {
  mut to_stderr : Bool
  mut quit : Bool
}

///|
let cli : Cli = { to_stderr: false, quit: false, }

///|
/// A line of chatter, routed by whether this run is producing a file.
///
/// A run that includes `.export` is writing a document to stdout, so the
/// banner, the echoed log and the response to any seeding statement all have to
/// go to stderr - otherwise they land inside the file, and the file's own
/// importer then rejects it as invalid JSON. The documented round trip
/// (`moon run cmd/main -- .export tsr > dump.tsr`) cannot work otherwise.
fn out(text : String) -> Unit {
  if cli.to_stderr {
    eprintln(text)
  } else {
    println(text)
  }
}

///|
/// Always-diagnostic output; never part of a document.
fn warn(text : String) -> Unit {
  eprintln(text)
}

///|
/// Pulls a `--side N` or `--side=N` option out of the argument list.
///
/// Returns the raw value text ("" when the option is absent), whether the option
/// appeared with no value after it, and the arguments with the option removed.
///
/// The option is allowed to sit anywhere among the commands, because a flag that
/// only works in first position is a flag people get wrong. Only the *first*
/// occurrence counts: `--side 3 --side 4` taking the last one would mean the
/// earlier flag silently did nothing.
///
/// Both spellings consume their own argument. `--side=N` once set the value and
/// left itself in the list, so it went on to be executed as SQL and the run
/// reported "Unsupported SQL statement: --side=3" after having already built the
/// database at the side that flag asked for.
///
/// The raw text is handed back rather than a side, so that "not a number" and
/// "out of range" are decided by `lattice_of` and reported the same way wherever
/// the value came from.
fn parse_side_option(args : ArrayView[String]) -> (String, Bool, Array[String]) {
  let rest : Array[String] = []
  let mut raw = ""
  let mut missing = false
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    // Recognised on every pass, not just until the first value lands: a second
    // `--side` has to be *consumed*, or it and its value go on to be executed as
    // SQL and the run fails on a flag it already honoured once.
    let mut consumed = false
    if a == "--side" {
      if i + 1 < args.length() {
        if raw == "" {
          raw = args[i + 1]
        }
        i = i + 1 // also consume the value
      } else if raw == "" {
        missing = true
      }
      consumed = true
    } else if @tesseract.starts_with(a, "--side=") {
      if raw == "" {
        raw = @tesseract.slice(a, 7, a.length())
      }
      consumed = true
    }
    if !consumed {
      rest.push(a)
    }
    i = i + 1
  }
  (raw, missing, rest)
}

///|
/// Resolves `--side` into a lattice, and returns it with the remaining
/// arguments.
///
/// A bad value is refused here, before any statement runs, so `--side` can never
/// leave a half-built database behind to be mistaken for a successful one.
fn lattice_from_args(
  args : ArrayView[String],
) -> Result[(@tesseract.Lattice, Array[String]), String] {
  let (raw, missing, rest) = parse_side_option(args)
  if missing {
    return Err("--side needs a value, as --side 4 or --side=4")
  }
  if raw == "" {
    return Ok((@tesseract.default_lattice(), rest))
  }
  match @tesseract.parse_int(raw) {
    None => Err("--side needs an integer, got '" + raw + "'")
    Some(n) =>
      match @tesseract.lattice_of(n.to_int64()) {
        Ok(l) => Ok((l, rest))
        Err(message) => Err("--side " + message)
      }
  }
}

///|
fn main {
  let all = @env.args()
  // args[0] is the path of the executable itself; the rest are ours.
  let argv = if all.length() > 0 { all[1:] } else { all }
  // Everything below reads the lattice's shape off this one value, so the
  // banner, the cursor range, `.solve` and `.export` all follow `--side`
  // together. The default stays 3, which is the lattice every existing `.tsr`
  // and `.db` file was written under.
  let (lat, args) = match lattice_from_args(argv) {
    Ok(pair) => pair
    Err(message) => {
      warn(message)
      return
    }
  }
  // The banner is a diagnostic, not output: `.export` writes a document to
  // stdout and this command is documented as redirecting it into a file, so
  // anything else on stdout ends up inside that file.
  warn(
    "Tesseract 4D - " +
    @tesseract.lattice_shape_text(lat) +
    " lattice, " +
    @tesseract.sudoku_line_count(lat).to_string() +
    " sudoku lines",
  )
  if args.length() == 0 {
    print_help()
    return
  }
  let logger = @tesseract.new_logger("tesseract")
  // A real command line gets real timestamps. The library default is the logical
  // counter, which is what keeps the tests comparable between runs; a surface
  // that prints stamps for a person should say when it happened, not how many
  // log lines preceded it. Set before `new_db`, which keeps its own copy.
  @tesseract.TesseractLogger::set_clock(logger, @tesseract.system_clock())
  let db = @tesseract.new_db("tesseract", lat, logger)
  @tesseract.TesseractLogger::set_echo(
    @tesseract.Tesseract::get_logger(db),
    true,
  )
  let mut k = 0
  while k < args.length() {
    if @tesseract.starts_with(args[k], ".export") {
      cli.to_stderr = true
    }
    k = k + 1
  }
  let mut i = 0
  while i < args.length() {
    // A command and its format arrive as two argv entries under ordinary shell
    // word-splitting: `-- .export md` is `.export` and `md`. A bare `.export`
    // matches on its own and exports the *default* format, then `md` runs as
    // SQL and fails - so `> dump.md` would hold an `.tsr` document under a
    // misleading name, with an error line beside it. Joining here makes the
    // split form mean the same as the quoted one.
    let mut arg = args[i]
    if arg == ".export" &&
      i + 1 < args.length() &&
      args[i + 1].length() > 0 &&
      args[i + 1].at(0) != '.' {
      arg = arg + " " + args[i + 1]
      i = i + 1
    }
    if cli.quit {
      i = i + 1
      continue
    }
    if arg == ".help" || arg == "-h" || arg == "--help" {
      print_help()
    } else if !handle_dot(db, arg) {
      out(@tesseract.format_response(@tesseract.execute(db, arg)))
    }
    i = i + 1
  }
}

///|
/// The command list, also printed when invoked with no arguments.
fn print_help() -> Unit {
  out("")
  out("usage: moon run cmd/main -- [--side N] <sql-or-command>...")
  out("")
  out("options:")
  out("  --side N                 cells per axis, 1..215 (default 3)")
  out("")
  out("commands:")
  out("  .help                   this list")
  out("  .status                 lattice occupancy and cursor")
  out("  .grid                   draw the lattice view")
  out("  .pos N | .pos (x,y,z,w) move the insert cursor")
  out("  .neighbours N           occupied cells sharing a line with N")
  out("  .solve                  fill every cell from the closed-form solution")
  out("  .verify                 check the digits against the sudoku rules")
  out("  .demo                   insert/select/update/delete tour")
  out("  .export tsr|md|sql      write the database to stdout")
  out("")
  out("anything else is executed as SQL, so statements keep their own quoting.")
  out("  moon run cmd/main -- " + example())
}

///|
/// The example invocation, built so the quoting survives being a literal.
fn example() -> String {
  let b = StringBuilder::StringBuilder()
  b.write_char('"')
  b.write_string("INSERT INTO tesseract (key,value) VALUES ('a','1') AT 5;")
  b.write_char('"')
  b.to_string()
}

///|
/// Runs a `.command`. Returns false when the line is not a dot command.
fn handle_dot(db : @tesseract.Tesseract, line : String) -> Bool {
  if line.length() == 0 || line.at(0) != '.' {
    return false
  }
  if line == ".status" {
    print_status(db)
    return true
  }
  if line == ".grid" {
    let cursor = @tesseract.Tesseract::status(db).current_position
    out(@tesseract.render_lattice(db, cursor))
    return true
  }
  if @tesseract.starts_with(line, ".pos ") {
    move_cursor(
      db,
      @tesseract.trim_ws(@tesseract.slice(line, 5, line.length())),
    )
    return true
  }
  if @tesseract.starts_with(line, ".neighbours ") {
    let arg = @tesseract.trim_ws(@tesseract.slice(line, 12, line.length()))
    match @tesseract.parse_int(arg) {
      Some(p) =>
        out(
          @tesseract.format_response(
            @tesseract.Tesseract::peer_query(db, p.to_int64()),
          ),
        )
      None => out("expected a position")
    }
    return true
  }
  if line == ".solve" {
    solve(db)
    return true
  }
  if line == ".verify" {
    verify(db)
    return true
  }
  if line == ".demo" {
    run_demo(db)
    return true
  }
  if @tesseract.starts_with(line, ".export") {
    let what = @tesseract.trim_ws(@tesseract.slice(line, 7, line.length()))
    if what == "md" || what == "markdown" {
      println(@tesseract.export_markdown(db))
    } else if what == "sql" {
      println(@tesseract.export_sql(db))
    } else if what == "" || what == "tsr" || what == "json" {
      println(@tesseract.export_tsr(db))
    } else {
      // Anything else used to fall through to the `.tsr` branch, so a typo
      // produced a valid-looking file in a format nobody asked for.
      warn("unknown export format '" + what + "'; use tsr, md or sql")
      return true
    }
    return true
  }
  if line == ".quit" || line == ".exit" {
    // Stop consuming arguments. It used to `return true` and carry on, so a
    // script that ended with `.quit` still ran everything after it.
    cli.quit = true
    return true
  }
  if line == ".help" || line == "-h" || line == "--help" {
    print_help()
    return true
  }
  out("unknown command: " + line + " (try .help)")
  true
}

///|
/// Occupancy and cursor readout.
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
}

///|
/// `.pos` — accepts a position or an `(x,y,z,w)` address.
fn move_cursor(db : @tesseract.Tesseract, arg : String) -> Unit {
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  let resolved = if @tesseract.starts_ci(arg, "(") {
    match @tesseract.parse_coords(lat, arg) {
      Some(c) => Some(@tesseract.position_of(lat, c))
      None => None
    }
  } else {
    match @tesseract.parse_int(arg) {
      Some(p) => Some(p.to_int64())
      None => None
    }
  }
  match resolved {
    Some(p) =>
      if @tesseract.position_in_bounds(lat, p) {
        @tesseract.Tesseract::set_position(db, p)
        out(
          "cursor -> " +
          p.to_string() +
          " " +
          @tesseract.format_coords(@tesseract.coords_of(lat, p).unwrap()),
        )
      } else {
        out(
          "out of range: " +
          p.to_string() +
          " (expected 1.." +
          lat.last_position.to_string() +
          ")",
        )
      }
    None => out("expected a position or an (x,y,z,w) address")
  }
}

///|
/// `.solve` — fills every cell from the closed-form solution.
fn solve(db : @tesseract.Tesseract) -> Unit {
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  out(
    "filling every cell from digit(x,y,z,w) = (x+y+z+w) mod " +
    lat.side.to_string() +
    " + 1",
  )
  let digits = @tesseract.canonical_digits(lat)
  let mut p = lat.first_position
  let mut ok = 0
  let mut first_failure = ""
  while p <= lat.last_position {
    let b = StringBuilder::StringBuilder()
    b.write_string("INSERT INTO tesseract (key, value, digit) VALUES ('cell_")
    b.write_object(p)
    b.write_string("', '{\"pos\": ")
    b.write_object(p)
    b.write_string("}', ")
    b.write_object(digits[@tesseract.slot_of(p)])
    b.write_string(") AT ")
    b.write_object(p)
    b.write_char(';')
    let r = @tesseract.execute(db, b.to_string())
    if r.success {
      ok = ok + 1
    } else if first_failure == "" {
      // A closed form can only overwrite a cell whose current digit does not
      // clash with its neighbours, so filling a half-finished puzzle is
      // legitimately refused at some positions. Reporting only the count made
      // `placed 80 digits` look like a success.
      first_failure = " first refused at position " +
        p.to_string() +
        ": " +
        r.error_code +
        " (" +
        r.error +
        ")"
    }
    p = p + 1L
  }
  out("placed " + ok.to_string() + " digits" + first_failure)
  print_status(db)
}

///|
/// `.verify` — checks the stored digits against the line and slab rules.
fn verify(db : @tesseract.Tesseract) -> Unit {
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  let digits = @tesseract.empty_digits(lat)
  let mut p = lat.first_position
  while p <= lat.last_position {
    match @tesseract.Tesseract::cell_at(db, p) {
      Some(cell) => @tesseract.set_digit(lat, digits, p, cell.digit)
      None => ()
    }
    p = p + 1L
  }
  let lv = @tesseract.line_violations(lat, digits)
  let sv = @tesseract.slab_violations(lat, digits)
  out("line violations : " + lv.length().to_string())
  report(lv)
  out("slab imbalances : " + sv.length().to_string())
  report(sv)
  if lv.length() == 0 && sv.length() == 0 {
    out("OK - every axis-parallel line holds 1.." + lat.max_digit.to_string())
  }
}

///|
/// Prints each message on its own line.
fn report(items : Array[String]) -> Unit {
  let mut i = 0
  while i < items.length() {
    out("  " + items[i])
    i = i + 1
  }
}

///|
/// `.demo` — the tour the C# view model's demo button ran, at 4D scale.
fn run_demo(db : @tesseract.Tesseract) -> Unit {
  out("1. clear")
  ignore(@tesseract.execute(db, "DELETE FROM tesseract;"))
  out("2. insert three records")
  ignore(
    @tesseract.execute(
      db, "INSERT INTO tesseract (key, value) VALUES ('user_001', '{\"age\": 25}');",
    ),
  )
  ignore(
    @tesseract.execute(
      db, "INSERT INTO tesseract (key, value) VALUES ('user_002', '{\"age\": 30}');",
    ),
  )
  ignore(
    @tesseract.execute(
      db, "INSERT INTO tesseract (key, value) VALUES ('user_003', '{\"age\": 28}');",
    ),
  )
  out("3. select all")
  out(
    @tesseract.format_response(
      @tesseract.execute(db, "SELECT * FROM tesseract;"),
    ),
  )
  out("4. update user_001")
  ignore(
    @tesseract.execute(
      db, "UPDATE tesseract SET value = '{\"age\": 26}' WHERE key = 'user_001';",
    ),
  )
  out("5. read it back")
  out(
    @tesseract.format_response(
      @tesseract.execute(db, "SELECT * FROM tesseract WHERE key = 'user_001';"),
    ),
  )
  out("6. place a sudoku digit at position 1")
  ignore(
    @tesseract.execute(
      db, "INSERT INTO tesseract (key, value, digit) VALUES ('d1', '{\"n\": 1}', 1) AT 1;",
    ),
  )
  out("7. position 3 shares a line with it, so digit 1 is refused")
  let clash = @tesseract.execute(
    db, "INSERT INTO tesseract (key, value, digit) VALUES ('d2', '{\"n\": 2}', 1) AT 3;",
  )
  out("   -> " + clash.error_code + " (" + clash.error + ")")
  out("8. occupied neighbours of position 1")
  out(@tesseract.format_response(@tesseract.Tesseract::peer_query(db, 1)))
  out("9. delete user_003 and report")
  ignore(
    @tesseract.execute(db, "DELETE FROM tesseract WHERE key = 'user_003';"),
  )
  print_status(db)
  out("demo complete")
}
