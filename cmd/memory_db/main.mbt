///|
/// A short-term memory that survives the process.
///
/// The library is `riantr/tesseract/src/tesseract_memory`; the durable store
/// is `riantr/tesseract/src/tesseract_memory_db`. This is the window onto
/// both, and it is a **separate binary** from `cmd/memory` for the reason
/// `cmd/persist` is separate from `cmd/main`: the store is a `.db` file, and
/// the `.db` adapter builds only for `native` and `wasm`. Putting it in
/// `cmd/memory` would take that binary off `js` and `wasm-gc`.
///
/// The commands are the same ones `cmd/memory` has — they live in
/// `riantr/tesseract/src/tesseract_memory_cli` — so the two binaries differ
/// in **where the memory is kept**, not in what they can do to it.
///
/// ```sh
/// moon run cmd/memory_db --target native -- --file notes.db "put a hello"
/// moon run cmd/memory_db --target native -- --file notes.db "keys"
/// moon run cmd/memory_db --target native -- --file notes.db "get a"
/// ```
///
/// The file is written after **every** command, so it is current when the
/// next command starts and current when the process ends. The store is swept
/// before it is written, so the file holds what is **live**: an entry whose
/// time was up is not in it, and it does not come back.
///
/// The **deadlines are absolute**, so a store that was closed and reopened
/// finds its entries with the time they had left, not with the time they were
/// given. And the **clock comes back with them**: a store on a manual clock
/// that is reopened comes back on the timeline it was left on, so `advance`
/// moves it from where it was rather than from zero.
///
/// The **tour** (`demo`) is refused here. It writes a handful of entries into
/// the store it is given, and this store is a file the caller keeps — a tour
/// that left three entries behind would be a surprise in it. The tour in
/// `cmd/memory` is the same tour over a store that ends with the process.
///
/// ## The index
///
/// `--index PATH` names a **SQL index** of the store's entries: a plain SQLite
/// table, one row for each word of each entry, so "which of my entries say
/// 'cat'?" is a lookup rather than a scan. The index is a file of its own, and
/// it is **derivative** — it holds nothing the entries do not, so it can be
/// thrown away and built again.
///
/// ```sh
/// moon run cmd/memory_db --target native -- --file notes.db --index notes.idx "put a the cat sat"
/// moon run cmd/memory_db --target native -- --file notes.db --index notes.idx "index"
/// moon run cmd/memory_db --target native -- --file notes.db --index notes.idx "index-find cat"
/// ```
///
/// The `index` command is the **explicit rebuild**: it puts the index back in
/// step with the store and says how far it had drifted. A rebuild of an index
/// that was already right changes **nothing** and says so — that is the proof
/// that the index holds nothing of its own.
///
/// The index is **not** rebuilt by the other commands. A command that changes
/// the store changes the store, and the index is the caller's to rebuild when
/// it wants it fresh. So `index-find` checks the index against the store
/// before it answers, and says so when the two disagree — a lookup that
/// answered from a stale index without saying so would be worse than no index.

///|
/// How this binary is run, for the help.
fn how_to_run() -> @tesseract_memory_cli.Usage {
  @tesseract_memory_cli.usage(
    "moon run cmd/memory_db --target native -- --file PATH [options] <command> [args]...",
    [
      "  --file PATH               the checkpoint file this memory is written to",
      "  --index PATH              the SQL index of this memory's entries",
    ],
    [
      "  index                     rebuild the index from the store, and say what changed",
      "  index-find <word>         the entries that contain the word",
    ],
  )
}

///|
/// The index path, and the arguments without it.
///
/// The index is this binary's own business — `cmd/memory` has none, and it
/// must not have one: the index is a `.db` file, and the `.db` adapter does
/// not build on every backend that binary does. So the flag is read here, and
/// the arguments it was in are taken out before the shared layer sees them.
/// A flag with no value after it is not a flag: it is left where it is, so
/// the shared layer reports it as the unknown command it is.
fn take_index(argv : ArrayView[String]) -> (String?, Array[String]) {
  let mut index : String? = None
  let rest : Array[String] = []
  let mut i = 0
  while i < argv.length() {
    let a = argv[i]
    if a == "--index" && i + 1 < argv.length() {
      index = Some(argv[i + 1])
      i = i + 2
      continue
    }
    rest.push(a)
    i = i + 1
  }
  (index, rest)
}

///|
/// Rebuilds the index from the store, and says what changed.
///
/// The store is what the index is built from, so the rebuild is the only thing
/// that puts the two in step. The report says how far the index was from the
/// store — and a rebuild of an index that was already right says nothing at
/// all, which is the proof that the index holds nothing of its own.
fn rebuild_index(path : String, m : @tesseract_memory.Memory) -> Unit {
  let index = match @tesseract_memory_index.open(path) {
    Ok(i) => i
    Err(message) => {
      @tesseract_memory_cli.warn(message)
      return
    }
  }
  match index.rebuild(m) {
    Ok(report) => {
      let rows = match index.rows() {
        Ok(n) => n.to_string()
        Err(message) => {
          @tesseract_memory_cli.warn(message)
          return
        }
      }
      @tesseract_memory_cli.out(
        "index " + index.path() + ": " + rows + " rows, " + report.describe(),
      )
    }
    Err(message) => @tesseract_memory_cli.warn(message)
  }
}

///|
/// The entries that contain a word.
///
/// The index is checked against the store **before** it answers, so a stale
/// index says so instead of quietly answering from the past. The check changes
/// nothing; the rebuild is a separate thing, on purpose.
fn find_in_index(
  path : String,
  word : String,
  m : @tesseract_memory.Memory,
) -> Unit {
  let index = match @tesseract_memory_index.open(path) {
    Ok(i) => i
    Err(message) => {
      @tesseract_memory_cli.warn(message)
      return
    }
  }
  match index.verify(m) {
    Ok(report) =>
      if report.changed > 0 || report.added > 0 || report.removed > 0 {
        @tesseract_memory_cli.warn(
          "the index at " +
          index.path() +
          " is out of step with the store: " +
          report.describe() +
          " (run `index` to rebuild it)",
        )
      }
    Err(message) => @tesseract_memory_cli.warn(message)
  }
  match index.lookup(word) {
    Ok(found) => {
      if found.length() == 0 {
        @tesseract_memory_cli.out(word + " -> (nothing)")
        return
      }
      for (scope, key) in found {
        @tesseract_memory_cli.out(word + " -> " + scope + "/" + key)
      }
    }
    Err(message) => @tesseract_memory_cli.warn(message)
  }
}

///|
fn main {
  let all = @env.args()
  let argv = if all.length() > 0 { all[1:] } else { all }
  let (index_path, rest) = take_index(argv)
  let (options, commands) = @tesseract_memory_cli.parse_session(rest)
  if commands.length() == 0 {
    @tesseract_memory_cli.print_help(how_to_run())
    return
  }
  match options.problem() {
    Some(message) => {
      @tesseract_memory_cli.warn(message)
      return
    }
    None => ()
  }
  // A durable memory without a file is not a durable memory: there would be
  // nothing to come back to.
  let path = match options.file {
    Some(p) => p
    None => {
      @tesseract_memory_cli.warn("a durable memory needs a file: --file <path>")
      @tesseract_memory_cli.print_help(how_to_run())
      return
    }
  }
  let clock = if options.manual {
    @tesseract_memory.memory_clock_manual(0L)
  } else {
    @tesseract_memory.memory_clock_system()
  }
  let store = match
    @tesseract_memory_db.open_with_clock(path, options.config(), clock) {
    Ok(s) => s
    Err(message) => {
      @tesseract_memory_cli.warn(message)
      return
    }
  }
  // The handle the store hands out is the store itself, so what the commands
  // write through it is what the checkpoint writes out.
  let m = store.memory()
  let mut scope = m.scope(options.scope_name)
  let mut k = 0
  while k < commands.length() {
    let text = commands[k]
    if @tesseract_memory_cli.is_demo(text) {
      @tesseract_memory_cli.warn(
        "the tour writes into the store; the in-memory tour is cmd/memory",
      )
    } else {
      let words = @tesseract_memory_cli.words_of(text)
      let verb = if words.length() > 0 { words[0] } else { "" }
      if verb == "index" || verb == "index-find" {
        // The index commands are this binary's own, because the index is a
        // `.db` file and the layer is shared with a binary that has no `.db`.
        let index_file = match index_path {
          Some(p) => p
          None => {
            @tesseract_memory_cli.warn("the index needs a file: --index <path>")
            k = k + 1
            continue
          }
        }
        if verb == "index" {
          rebuild_index(index_file, m)
        } else if words.length() < 2 {
          @tesseract_memory_cli.warn("index-find needs a word")
        } else {
          find_in_index(index_file, words[1], m)
        }
      } else {
        scope = @tesseract_memory_cli.run_command(m, scope, text, how_to_run())
      }
    }
    // The file is written after every command, so it is current when the next
    // command starts, and current when the process ends.
    match store.checkpoint() {
      Ok(_) => ()
      Err(message) =>
        @tesseract_memory_cli.warn(
          "could not write the checkpoint to " + store.path() + ": " + message,
        )
    }
    k = k + 1
  }
}
