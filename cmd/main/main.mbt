///|
/// SudokuDB 4D — command line front end.
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
/// moon run cmd/main -- "INSERT INTO sudokuDB (key,value) VALUES ('a','1') AT 5;" "SELECT * FROM sudokuDB;"
/// moon run cmd/main -- .solve .verify
/// moon run cmd/main -- .export sdb > dump.sdb
/// ```
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
/// (`moon run cmd/main -- .export sdb > dump.sdb`) cannot work otherwise.
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
fn main {
  let all = @env.args()
  // args[0] is the path of the executable itself; the rest are ours.
  let args = if all.length() > 0 { all[1:] } else { all }
  // The banner is a diagnostic, not output: `.export` writes a document to
  // stdout and this command is documented as redirecting it into a file, so
  // anything else on stdout ends up inside that file.
  warn("SudokuDB 4D - 3x3x3x3 lattice, 81 cells, 108 sudoku lines")
  if args.length() == 0 {
    print_help()
    return
  }
  let logger = @sudokudb.new_logger("sudokuDB")
  let db = @sudokudb.new_db("sudokuDB", logger)
  @sudokudb.SudokuDBLogger::set_echo(@sudokudb.SudokuDB::get_logger(db), true)
  let mut k = 0
  while k < args.length() {
    if @sudokudb.starts_with(args[k], ".export") {
      cli.to_stderr = true
    }
    k = k + 1
  }
  let mut i = 0
  while i < args.length() {
    // A command and its format arrive as two argv entries under ordinary shell
    // word-splitting: `-- .export md` is `.export` and `md`. A bare `.export`
    // matches on its own and exports the *default* format, then `md` runs as
    // SQL and fails - so `> dump.md` would hold an `.sdb` document under a
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
      out(@sudokudb.format_response(@sudokudb.execute(db, arg)))
    }
    i = i + 1
  }
}

///|
/// The command list, also printed when invoked with no arguments.
fn print_help() -> Unit {
  out("")
  out("usage: moon run cmd/main -- <sql-or-command>...")
  out("")
  out("commands:")
  out("  .help                   this list")
  out("  .status                 lattice occupancy and cursor")
  out("  .grid                   draw the 3x3x3x3 lattice view")
  out("  .pos N | .pos (x,y,z,w) move the insert cursor")
  out("  .neighbours N           occupied cells sharing a line with N")
  out("  .solve                  fill every cell from the closed-form solution")
  out("  .verify                 check the digits against the sudoku rules")
  out("  .demo                   insert/select/update/delete tour")
  out("  .export sdb|md|sql      write the database to stdout")
  out("")
  out("anything else is executed as SQL, so statements keep their own quoting.")
  out("  moon run cmd/main -- " + example())
}

///|
/// The example invocation, built so the quoting survives being a literal.
fn example() -> String {
  let b = StringBuilder::StringBuilder()
  b.write_char('"')
  b.write_string("INSERT INTO sudokuDB (key,value) VALUES ('a','1') AT 5;")
  b.write_char('"')
  b.to_string()
}

///|
/// Runs a `.command`. Returns false when the line is not a dot command.
fn handle_dot(db : @sudokudb.SudokuDB, line : String) -> Bool {
  if line.length() == 0 || line.at(0) != '.' {
    return false
  }
  if line == ".status" {
    print_status(db)
    return true
  }
  if line == ".grid" {
    let cursor = @sudokudb.SudokuDB::status(db).current_position
    out(@sudokudb.render_lattice(db, cursor))
    return true
  }
  if @sudokudb.starts_with(line, ".pos ") {
    move_cursor(db, @sudokudb.trim_ws(@sudokudb.slice(line, 5, line.length())))
    return true
  }
  if @sudokudb.starts_with(line, ".neighbours ") {
    let arg = @sudokudb.trim_ws(@sudokudb.slice(line, 12, line.length()))
    match @sudokudb.parse_int(arg) {
      Some(p) =>
        out(@sudokudb.format_response(@sudokudb.SudokuDB::peer_query(db, p)))
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
  if @sudokudb.starts_with(line, ".export") {
    let what = @sudokudb.trim_ws(@sudokudb.slice(line, 7, line.length()))
    if what == "md" || what == "markdown" {
      println(@sudokudb.export_markdown(db))
    } else if what == "sql" {
      println(@sudokudb.export_sql(db))
    } else if what == "" || what == "sdb" || what == "json" {
      println(@sudokudb.export_sdb(db))
    } else {
      // Anything else used to fall through to the `.sdb` branch, so a typo
      // produced a valid-looking file in a format nobody asked for.
      warn("unknown export format '" + what + "'; use sdb, md or sql")
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
fn print_status(db : @sudokudb.SudokuDB) -> Unit {
  let s = @sudokudb.SudokuDB::status(db)
  let here = @sudokudb.coords_of(s.current_position).unwrap()
  out("database: " + s.db_name)
  out("lattice : 3x3x3x3 = 81 cells, 108 lines, 12 slabs")
  out("records : " + s.current_count.to_string())
  out("digits  : " + s.digit_count.to_string())
  out(
    "cursor  : " +
    s.current_position.to_string() +
    " " +
    @sudokudb.format_coords(here),
  )
}

///|
/// `.pos` — accepts a position or an `(x,y,z,w)` address.
fn move_cursor(db : @sudokudb.SudokuDB, arg : String) -> Unit {
  let resolved = if @sudokudb.starts_ci(arg, "(") {
    match @sudokudb.parse_coords(arg) {
      Some(c) => Some(@sudokudb.position_of(c))
      None => None
    }
  } else {
    match @sudokudb.parse_int(arg) {
      Some(p) => Some(p)
      None => None
    }
  }
  match resolved {
    Some(p) =>
      if @sudokudb.position_in_bounds(p) {
        @sudokudb.SudokuDB::set_position(db, p)
        out(
          "cursor -> " +
          p.to_string() +
          " " +
          @sudokudb.format_coords(@sudokudb.coords_of(p).unwrap()),
        )
      } else {
        out("out of range: " + p.to_string() + " (expected 1..81)")
      }
    None => out("expected a position or an (x,y,z,w) address")
  }
}

///|
/// `.solve` — fills all 81 cells from the closed-form solution.
fn solve(db : @sudokudb.SudokuDB) -> Unit {
  out("filling every cell from digit(x,y,z,w) = (x+y+z+w) mod 3 + 1")
  let digits = @sudokudb.canonical_digits()
  let mut p = 1
  let mut ok = 0
  let mut first_failure = ""
  while p <= @sudokudb.LAST_POSITION {
    let b = StringBuilder::StringBuilder()
    b.write_string("INSERT INTO sudokuDB (key, value, digit) VALUES ('cell_")
    b.write_object(p)
    b.write_string("', '{\"pos\": ")
    b.write_object(p)
    b.write_string("}', ")
    b.write_object(digits[p - 1])
    b.write_string(") AT ")
    b.write_object(p)
    b.write_char(';')
    let r = @sudokudb.execute(db, b.to_string())
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
    p = p + 1
  }
  out("placed " + ok.to_string() + " digits" + first_failure)
  print_status(db)
}

///|
/// `.verify` — checks the stored digits against the line and slab rules.
fn verify(db : @sudokudb.SudokuDB) -> Unit {
  let digits = @sudokudb.empty_digits()
  let mut p = 1
  while p <= @sudokudb.LAST_POSITION {
    match @sudokudb.SudokuDB::cell_at(db, p) {
      Some(cell) => @sudokudb.set_digit(digits, p, cell.digit)
      None => ()
    }
    p = p + 1
  }
  let lv = @sudokudb.line_violations(digits)
  let sv = @sudokudb.slab_violations(digits)
  out("line violations : " + lv.length().to_string())
  report(lv)
  out("slab imbalances : " + sv.length().to_string())
  report(sv)
  if lv.length() == 0 && sv.length() == 0 {
    out("OK - every axis-parallel line holds 1, 2 and 3")
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
fn run_demo(db : @sudokudb.SudokuDB) -> Unit {
  out("1. clear")
  ignore(@sudokudb.execute(db, "DELETE FROM sudokuDB;"))
  out("2. insert three records")
  ignore(
    @sudokudb.execute(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('user_001', '{\"age\": 25}');",
    ),
  )
  ignore(
    @sudokudb.execute(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('user_002', '{\"age\": 30}');",
    ),
  )
  ignore(
    @sudokudb.execute(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('user_003', '{\"age\": 28}');",
    ),
  )
  out("3. select all")
  out(
    @sudokudb.format_response(@sudokudb.execute(db, "SELECT * FROM sudokuDB;")),
  )
  out("4. update user_001")
  ignore(
    @sudokudb.execute(
      db, "UPDATE sudokuDB SET value = '{\"age\": 26}' WHERE key = 'user_001';",
    ),
  )
  out("5. read it back")
  out(
    @sudokudb.format_response(
      @sudokudb.execute(db, "SELECT * FROM sudokuDB WHERE key = 'user_001';"),
    ),
  )
  out("6. place a sudoku digit at position 1")
  ignore(
    @sudokudb.execute(
      db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('d1', '{\"n\": 1}', 1) AT 1;",
    ),
  )
  out("7. position 3 shares a line with it, so digit 1 is refused")
  let clash = @sudokudb.execute(
    db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('d2', '{\"n\": 2}', 1) AT 3;",
  )
  out("   -> " + clash.error_code + " (" + clash.error + ")")
  out("8. occupied neighbours of position 1")
  out(@sudokudb.format_response(@sudokudb.SudokuDB::peer_query(db, 1)))
  out("9. delete user_003 and report")
  ignore(@sudokudb.execute(db, "DELETE FROM sudokuDB WHERE key = 'user_003';"))
  print_status(db)
  out("demo complete")
}
