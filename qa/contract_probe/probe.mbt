///|
/// The checkpoint format contract, measured against the **published** package.
///
/// The durable memory's checkpoint is a file with a format: a header cell that
/// carries a version and a clock, and one cell per entry after it. A format is
/// a contract with whoever has to read the file next, so the questions this
/// probe answers are the ones a consumer would ask:
///
/// - **Does a file this build writes come back out of this build's reader?**
///   If it does not, the checkpoint is write-only.
/// - **What does the reader do with a file it does not understand?** A file
///   whose header carries a version this build does not know has to be either
///   refused cleanly or read as something it is not. The format's own words
///   are "refused rather than half-read", so the probe checks for a refusal
///   and reports what actually happens.
/// - **What are the constants, byte for byte?** A consumer that has to read a
///   checkpoint written by another build needs the magic and the version as
///   bytes, not as prose.
///
/// This file holds the machinery; `probe_test.mbt` holds the questions.

///|
/// The directory the probe works in.
///
/// The harness sets `TESSERACT_PROBE_DIR` so the files land somewhere the
/// harness can clean up. Without it the probe uses the host's temporary
/// directory — never the package's own directory, which would leave
/// checkpoints in the source tree.
pub fn probe_dir() -> String {
  match @env.get_env_var("TESSERACT_PROBE_DIR") {
    Some(d) => d
    None =>
      match @env.get_env_var("TEMP") {
        Some(d) => d
        None =>
          match @env.get_env_var("TMPDIR") {
            Some(d) => d
            None =>
              match @env.current_dir() {
                Some(d) => d
                None => "."
              }
          }
      }
  }
}

///|
/// The path of one probe file.
pub fn probe_path(name : String) -> String {
  probe_dir() + "/" + name
}

///|
/// A string, or a marker when there is none.
pub fn opt_str(value : String?) -> String {
  match value {
    Some(s) => s
    None => "<none>"
  }
}

///|
/// The instant the probe's manual clock sits at.
///
/// It is a fixed instant rather than the wall clock, so the deadlines in the
/// checkpoint are the same every run and the probe's numbers can be compared
/// between runs.
pub const PROBE_NOW : Int64 = 1700000000000L

///|
/// Removes a probe file if it is there.
///
/// The probe's files land in a directory that survives the run — the host's
/// temporary directory, or the one the harness names — so a probe that
/// inherits the last run's file is not measuring what it says it measures. A
/// checkpoint left with a rewritten header cannot be opened, and the run that
/// follows reports the *previous* run's corruption as its own result.
pub fn remove_probe_file(path : String) -> Unit {
  @xfs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// Writes a checkpoint holding one entry that lives for a minute and one that
/// never expires.
///
/// The manual clock is what makes the header matter: a checkpoint carries the
/// clock it was written on, and a reader that throws that away reads the
/// entries against a different timeline.
pub fn write_checkpoint(path : String, ttl : @tesseract_memory.Ttl) -> Unit {
  remove_probe_file(path)
  let config = @tesseract_memory.default_config()
  let clock = @tesseract_memory.memory_clock_manual(PROBE_NOW)
  let store = match @tesseract_memory_db.open_with_clock(path, config, clock) {
    Ok(s) => s
    Err(message) => {
      println("PROBE write_error " + message)
      return
    }
  }
  match
    @tesseract_memory_db.DurableMemory::put_with_ttl(store, "alpha", "1", ttl) {
    Ok(_) => ()
    Err(message) => println("PROBE write_error " + message)
  }
  match @tesseract_memory_db.DurableMemory::put(store, "beta", "2") {
    Ok(_) => ()
    Err(message) => println("PROBE write_error " + message)
  }
  match @tesseract_memory_db.DurableMemory::checkpoint(store) {
    Ok(n) => println("PROBE written_cells " + n.to_string())
    Err(message) => println("PROBE write_error " + message)
  }
}

///|
/// The header row's value, read straight out of the file.
pub fn read_header_value(path : String) -> String raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "SELECT value FROM sudoku_cells WHERE grid_position = 1",
  )
  defer stmt.finalize()
  if stmt.step() {
    let value : String = stmt.column(index=0)
    return value
  }
  ""
}

///|
/// The header row's key, read straight out of the file.
pub fn read_header_key(path : String) -> String raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "SELECT key FROM sudoku_cells WHERE grid_position = 1",
  )
  defer stmt.finalize()
  if stmt.step() {
    let key : String = stmt.column(index=0)
    return key
  }
  ""
}

///|
/// Rewrites the header's format version and leaves everything else alone.
///
/// The rewrite goes through the JSON the writer produced, so the only thing
/// that changes in the file is the version itself.
pub fn rewrite_header_version(path : String, version : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "SELECT value FROM sudoku_cells WHERE grid_position = 1",
  )
  defer stmt.finalize()
  let old = if stmt.step() { stmt.column(index=0) } else { "" }
  let parsed = @json.parse(old) catch { _ => return }
  match parsed {
    @builtin.Json::Object(obj) => {
      obj.set("format", @json.to_json(version))
      let fresh = @json.to_json(obj).stringify()
      let update = conn.prepare(
        "UPDATE sudoku_cells SET value = ? WHERE grid_position = 1",
      )
      defer update.finalize()
      update.bind(index=1, fresh)
      ignore(update.step())
    }
    _ => ()
  }
}

///|
/// Rewrites the header row's key.
pub fn rewrite_header_key(path : String, key : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "UPDATE sudoku_cells SET key = ? WHERE grid_position = 1",
  )
  defer stmt.finalize()
  stmt.bind(index=1, key)
  ignore(stmt.step())
}

///|
/// Removes the header row altogether.
pub fn delete_header_row(path : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare("DELETE FROM sudoku_cells WHERE grid_position = 1")
  defer stmt.finalize()
  ignore(stmt.step())
}

///|
/// Writes a file that is not a database at all.
pub fn write_garbage(path : String) -> Unit {
  @xfs.write_string_to_file(
    path, "this is not a database, it is a sentence about one",
  ) catch {
    _ => ()
  }
}

///|
/// Writes a file with nothing in it.
pub fn write_empty(path : String) -> Unit {
  @xfs.write_string_to_file(path, "") catch {
    _ => ()
  }
}
