///|
/// A short-term memory, from a shell.
///
/// The library is `riantr/tesseract/src/tesseract_memory`; this is the window
/// onto it. Every argument is one command, and they run in order against one
/// shared memory — the same shape `cmd/main` uses for its statements, because
/// a memory is only interesting as a *sequence* of things done to it.
///
/// ```sh
/// moon run cmd/memory -- "put greeting hello world" "get greeting"
/// moon run cmd/memory -- --capacity 3 "put a 1" "put b 2" "put c 3" "put d 4" "keys"
/// moon run cmd/memory -- --manual-clock "put a x --ttl 1000" "advance 1000" "get a"
/// moon run cmd/memory -- --scope work "put a 1" "put b 2" "scopes"
/// moon run cmd/memory -- "put a x --meta kind=note" "entries --where kind=note"
/// moon run cmd/memory -- demo
/// ```
///
/// The commands themselves live in `riantr/tesseract/src/tesseract_memory_cli`,
/// which `cmd/memory_db` shares. The two binaries differ in **where the
/// memory is kept**, not in what they can do to it: this one keeps it in the
/// process and forgets it when the process ends, and the other writes it to a
/// file that outlives it.
///
/// The options come before the commands and configure the store:
///
/// | option | meaning |
/// |---|---|
/// | `--capacity N` | how many entries the memory holds (default 100) |
/// | `--max-bytes N` | a budget for the stored values, in UTF-8 bytes (0: none) |
/// | `--ttl MS` | the default lifetime of a `put` (default: never) |
/// | `--evict NAME` | `lru`, `lfu`, `expiry` or `oldest` |
/// | `--by NAME` | `jaccard`, `cosine`, `containment` or `structure` |
/// | `--half-life MS` | halve the weight of an entry every MS (0: no decay) |
/// | `--manual-clock` | a clock that only `advance` moves |
/// | `--scope NAME` | the scope the commands work in (default: `default`) |
///
/// `--manual-clock` is what makes the TTL visible: nothing expires until the
/// clock is moved, so the demo shows the boundary rather than a race.
///
/// `--scope` picks the **partition** of the keyspace the commands work in.
/// The scopes of one memory share its clock, its budget and its statistics:
/// the capacity and the byte budget are the store's, so a write into one
/// scope can evict an entry from another. `scopes` lists the ones that hold
/// something, `scope <name>` switches to another one, and `search-all` looks
/// in all of them at once.
///
/// The **labels** say what an entry is. `put` writes them with `--meta k=v`,
/// and the searches and `entries` read them back with `--where k=v`,
/// `--where k` and `--without k`. A filter chooses the candidates, so an
/// entry the filter turns away is not looked at at all — even when it would
/// have been the better match.
///
/// The **pin** says an entry is never thrown away to make room for another
/// one. `put --pinned` writes a pinned entry, and `pin` and `unpin` change
/// the pin of an entry that is already there. The pin is absolute: a store
/// that cannot make room for a write without breaking a pin refuses the write
/// rather than breaking it.

///|
/// Everything the commands report goes to stdout; the banner and every failure
/// go to stderr. There is no export here writing a document, so the split is
/// only to keep a failure out of a pipeline that reads stdout.

///|
/// How this binary is run, for the help.
fn how_to_run() -> @tesseract_memory_cli.Usage {
  @tesseract_memory_cli.usage(
    "moon run cmd/memory -- [options] <command> [args]...",
    [],
    [],
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
  // A capacity of zero or less cannot be honoured, and a negative budget
  // would read as the one value that means no limit at all. The library
  // replaces a setting it cannot use, but a person who typed a flag deserves
  // to be told, not to be given a different memory than they asked for.
  match options.problem() {
    Some(message) => {
      @tesseract_memory_cli.warn(message)
      return
    }
    None => ()
  }
  // This binary keeps its memory in the process. A file is the other
  // binary's business, and it is a business that needs a different build:
  // the file is a `.db`, and the `.db` adapter does not build on every
  // backend this one does.
  match options.file {
    Some(_) => {
      @tesseract_memory_cli.warn(
        "this binary keeps its memory in the process; the durable one is cmd/memory_db",
      )
      return
    }
    None => ()
  }
  let config = options.config()
  let m = if options.manual {
    @tesseract_memory.new_memory_with_clock(
      config,
      @tesseract_memory.memory_clock_manual(0L),
    )
  } else {
    @tesseract_memory.new_memory_with(config)
  }
  let mut scope = m.scope(options.scope_name)
  let mut k = 0
  while k < commands.length() {
    scope = @tesseract_memory_cli.run_command(
      m,
      scope,
      commands[k],
      how_to_run(),
    )
    k = k + 1
  }
}
