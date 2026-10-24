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

///|
/// How this binary is run, for the help.
fn how_to_run() -> @tesseract_memory_cli.Usage {
  @tesseract_memory_cli.usage(
    "moon run cmd/memory_db --target native -- --file PATH [options] <command> [args]...",
    [
      "  --file PATH               the checkpoint file this memory is written to",
    ],
  )
}

///|
fn main {
  let all = @env.args()
  let argv = if all.length() > 0 { all[1:] } else { all }
  let (options, commands) = @tesseract_memory_cli.parse_session(argv)
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
      scope = @tesseract_memory_cli.run_command(m, scope, text, how_to_run())
    }
    // The file is written after every command, so it is current when the next
    // command starts, and current when the process ends.
    match store.checkpoint() {
      Ok(_) => ()
      Err(message) =>
        @tesseract_memory_cli.warn("could not write the checkpoint: " + message)
    }
    k = k + 1
  }
}
