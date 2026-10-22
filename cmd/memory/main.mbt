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
/// moon run cmd/memory -- demo
/// ```
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

///|
/// Everything the commands report goes to stdout; the banner and every failure
/// go to stderr. There is no export here writing a document, so the split is
/// only to keep a failure out of a pipeline that reads stdout.
fn out(text : String) -> Unit {
  println(text)
}

///|
/// Always-diagnostic output.
fn warn(text : String) -> Unit {
  eprintln(text)
}

///|
/// Split a command into its words, on runs of whitespace.
fn split_ws(text : String) -> Array[String] {
  let out : Array[String] = []
  let n = text.length()
  let mut start = -1
  let mut i = 0
  while i < n {
    let c = text.at(i).to_int()
    let space = c == 32 || c == 9 || c == 10 || c == 13
    if space {
      if start >= 0 {
        out.push(@tesseract.slice(text, start, i))
        start = -1
      }
    } else if start < 0 {
      start = i
    }
    i = i + 1
  }
  if start >= 0 {
    out.push(@tesseract.slice(text, start, n))
  }
  out
}

///|
/// The eviction policy a name stands for.
fn eviction_of(name : String) -> @tesseract_memory.EvictionPolicy {
  if name == "lfu" {
    @tesseract_memory.evict_lfu()
  } else if name == "expiry" {
    @tesseract_memory.evict_soonest_expiry()
  } else if name == "oldest" {
    @tesseract_memory.evict_oldest()
  } else {
    @tesseract_memory.evict_lru()
  }
}

///|
/// The similarity a name stands for.
fn similarity_of(name : String) -> @tesseract_memory.Similarity {
  if name == "cosine" {
    @tesseract_memory.similarity_cosine()
  } else if name == "containment" {
    @tesseract_memory.similarity_containment()
  } else if name == "structure" {
    @tesseract_memory.similarity_structure()
  } else {
    @tesseract_memory.similarity_jaccard()
  }
}

///|
/// A TTL from a number of milliseconds.
fn ttl_of(ms : Int64) -> @tesseract_memory.Ttl {
  @tesseract_memory.ttl_absolute(ms)
}

///|
fn print_help() -> Unit {
  out("")
  out("usage: moon run cmd/memory -- [options] <command> [args]...")
  out("")
  out("options:")
  out(
    "  --capacity N              how many entries the memory holds (default 100)",
  )
  out(
    "  --max-bytes N             a budget for the stored values, in UTF-8 bytes (0: none)",
  )
  out(
    "  --ttl MS                  the default lifetime of a put (default: never)",
  )
  out("  --evict NAME              lru | lfu | expiry | oldest   (default lru)")
  out("  --by NAME                 jaccard | cosine | containment | structure")
  out(
    "  --half-life MS            halve an entry's weight every MS (0: no decay)",
  )
  out("  --manual-clock            a clock that only the advance command moves")
  out(
    "  --scope NAME              the scope the commands work in (default: default)",
  )
  out("")
  out("commands:")
  out("  put <key> <value...>      remember a value")
  out("  put <key> <value...> --ttl MS --sliding")
  out("  put <key> <value...> --importance N   how much it counts, in (0, 1]")
  out("  get <key>                 read a value")
  out("  del <key>                 forget a key")
  out("  touch <key>               refresh a key without reading it")
  out("  keys                      the live keys")
  out("  entries                   the live entries, with their ages")
  out("  search <query...> [-k N] the entries most like the query")
  out("  search-all <query...>     the same, over every scope")
  out("  scopes                    the scopes that hold something")
  out("  scope <name>              work in another scope from here on")
  out("  sweep                     drop what has expired")
  out("  stats                     what the memory has done")
  out("  advance <ms>              move a manual clock forward")
  out("  clear                     forget everything in this scope")
  out("  clear-all                 forget everything in every scope")
  out("  demo                      a short tour")
  out("")
}

///|
/// The short tour, on a manual clock so every step is deterministic.
fn demo(m : @tesseract_memory.Memory) -> Unit {
  out("a short-term memory, on a clock that only moves when it is told")
  out("")
  out("1. remember three things")
  ignore(
    m.put_with_ttl(
      "greeting",
      "hello there, general kenobi",
      @tesseract_memory.ttl_sliding(5000L),
    ),
  )
  ignore(
    m.put_with_ttl(
      "note",
      "the cat sat on the mat",
      @tesseract_memory.ttl_absolute(5000L),
    ),
  )
  ignore(m.put("shape", "{\"name\":\"ada\",\"age\":36}"))
  out("   keys -> " + m.keys().join(", "))
  out("")
  out("2. find the entries that are like 'cat'")
  out("   (the store's similarity, jaccard: shared words over combined words)")
  for hit in m.search("cat", 3) {
    out("   " + hit.key + "  " + format_score(hit.score) + "  " + hit.value)
  }
  out("")
  out("3. compare by shape instead of by words")
  out("   (structure: shared leaf paths over combined leaf paths)")
  let shape_query = "{\"name\":\"x\"}"
  for entry in m.entries() {
    let score = @tesseract_memory.similarity_score(
      shape_query,
      entry.value,
      @tesseract_memory.similarity_structure(),
    )
    if score > 0.0 {
      out("   " + entry.key + "  " + format_score(score) + "  " + entry.value)
    }
  }
  out("")
  out("4. read the greeting, so its sliding deadline moves")
  ignore(m.advance(4000L))
  ignore(m.get("greeting"))
  out("   t+4000ms: greeting read, so its deadline moved to t+9000ms")
  ignore(m.advance(2000L))
  out("")
  out("5. the sliding entry is still there; the absolute one is not")
  out("   t+6000ms: greeting -> " + render(m.get("greeting")))
  out(
    "   t+6000ms: note     -> " +
    render(m.get("note")) +
    "  (deadline was t+5000ms)",
  )
  out("")
  out("6. when the store is full, the least recently used entry goes")
  let small = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_lru()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(small.put("first", "1"))
  ignore(small.advance(100L))
  ignore(small.put("second", "2"))
  ignore(small.advance(100L))
  ignore(small.get("first"))
  ignore(small.put("third", "3"))
  out(
    "   keys -> " +
    small.keys().join(", ") +
    "   (first was read, so second went)",
  )
  out("")
  out("7. a scope is a partition of the keyspace, not a second store")
  ignore(m.scope("work").put("todo", "ship 0.1.7"))
  ignore(m.scope("work").put("greeting", "hello from the work scope"))
  out("   scopes    -> " + m.scopes().join(", "))
  out(
    "   work keys -> " +
    m.scope("work").keys().join(", ") +
    "   (the default scope cannot see them)",
  )
  out("   the default scope still has: " + m.keys().join(", "))
  out("")
  out("8. the store, and what it did")
  let s = m.stats()
  out(
    "   size      " + m.size().to_string() + " of " + m.capacity().to_string(),
  )
  out(bytes_line(m, "   "))
  out("   puts      " + s.puts.to_string())
  out("   gets      " + s.gets.to_string())
  out("   hits      " + s.hits.to_string())
  out("   misses    " + s.misses.to_string())
  out("   evictions " + s.evictions.to_string())
  out("   expired   " + s.expirations.to_string())
}

///|
/// A value, or the word that says there was none.
fn render(value : String?) -> String {
  match value {
    None => "(nothing)"
    Some(v) => v
  }
}

///|
/// A score to three decimals.
fn format_score(score : Double) -> String {
  let scaled = (score * 1000.0).round().to_int64()
  (scaled / 1000L).to_string() + "." + @tesseract.pad_number(scaled % 1000L, 3)
}

///|
/// The byte total, and the budget it is measured against.
///
/// A budget of zero is no budget, and "of 0" would read like a store that is
/// over its limit by everything it holds. So the limit says what it is.
///
/// The total is the **store's**: the budget is spent across every scope, so
/// this is the number of the whole pool and not of one partition of it.
fn bytes_line(m : @tesseract_memory.Memory, indent : String) -> String {
  let used = m.size_bytes().to_string()
  let limit = m.max_bytes()
  if limit == 0L {
    indent + "bytes     " + used + " (no limit)"
  } else {
    indent + "bytes     " + used + " of " + limit.to_string()
  }
}

///|
fn main {
  let all = @env.args()
  let argv = if all.length() > 0 { all[1:] } else { all }
  let mut capacity = 100
  let mut max_bytes = 0L
  let mut default_ttl = @tesseract_memory.ttl_never()
  let mut eviction = @tesseract_memory.evict_lru()
  let mut similarity = @tesseract_memory.similarity_jaccard()
  let mut recency = @tesseract_memory.recency_none()
  let mut manual = false
  let mut scope_name = @tesseract_memory.default_scope_name()
  let commands : Array[String] = []
  let mut i = 0
  while i < argv.length() {
    let a = argv[i]
    if a == "--capacity" && i + 1 < argv.length() {
      capacity = @tesseract.parse_int(argv[i + 1]).unwrap_or(100)
      i = i + 2
      continue
    }
    if a == "--max-bytes" && i + 1 < argv.length() {
      max_bytes = @tesseract.parse_int(argv[i + 1]).unwrap_or(0).to_int64()
      i = i + 2
      continue
    }
    if a == "--ttl" && i + 1 < argv.length() {
      default_ttl = ttl_of(
        @tesseract.parse_int(argv[i + 1]).unwrap_or(0).to_int64(),
      )
      i = i + 2
      continue
    }
    if a == "--evict" && i + 1 < argv.length() {
      eviction = eviction_of(argv[i + 1])
      i = i + 2
      continue
    }
    if a == "--by" && i + 1 < argv.length() {
      similarity = similarity_of(argv[i + 1])
      i = i + 2
      continue
    }
    if a == "--half-life" && i + 1 < argv.length() {
      let ms = @tesseract.parse_int(argv[i + 1]).unwrap_or(0).to_int64()
      if ms > 0L {
        recency = @tesseract_memory.recency_decay(ms)
      }
      i = i + 2
      continue
    }
    if a == "--manual-clock" {
      manual = true
      i = i + 1
      continue
    }
    if a == "--scope" && i + 1 < argv.length() {
      scope_name = argv[i + 1]
      i = i + 2
      continue
    }
    commands.push(a)
    i = i + 1
  }
  if commands.length() == 0 {
    print_help()
    return
  }
  // A capacity of zero or less cannot be honoured, and a negative budget
  // would read as the one value that means no limit at all. The library
  // replaces a setting it cannot use, but a person who typed a flag deserves
  // to be told, not to be given a different memory than they asked for.
  if capacity <= 0 {
    warn("the capacity must be a positive number of entries")
    return
  }
  if max_bytes < 0L {
    warn("the byte budget cannot be negative (0 means no budget)")
    return
  }
  let config = @tesseract_memory.default_config()
    .with_capacity(capacity)
    .with_max_bytes(max_bytes)
    .with_default_ttl(default_ttl)
    .with_eviction(eviction)
    .with_similarity(similarity)
    .with_recency(recency)
  let m = if manual {
    @tesseract_memory.new_memory_with_clock(
      config,
      @tesseract_memory.memory_clock_manual(0L),
    )
  } else {
    @tesseract_memory.new_memory_with(config)
  }
  let mut scope = m.scope(scope_name)
  let mut k = 0
  while k < commands.length() {
    scope = run(m, scope, commands[k])
    k = k + 1
  }
}

///|
/// One command.
///
/// Returns the scope the **next** command works in: the `scope` command
/// changes it, and every other command leaves it alone.
fn run(
  m : @tesseract_memory.Memory,
  scope : @tesseract_memory.Scope,
  text : String,
) -> @tesseract_memory.Scope {
  let words = split_ws(text)
  if words.length() == 0 {
    return scope
  }
  let verb = words[0]
  if verb == "scope" {
    if words.length() < 2 {
      out(scope.name())
      return scope
    }
    let next = m.scope(words[1])
    out("scope -> " + next.name())
    return next
  }
  command(m, scope, words)
  scope
}

///|
/// One action, against one scope.
fn command(
  m : @tesseract_memory.Memory,
  scope : @tesseract_memory.Scope,
  words : Array[String],
) -> Unit {
  let verb = words[0]
  if verb == "help" || verb == "--help" || verb == "-h" {
    print_help()
    return
  }
  if verb == "demo" {
    demo(m)
    return
  }
  if verb == "put" {
    put(scope, words)
    return
  }
  if verb == "get" {
    if words.length() < 2 {
      warn("get needs a key")
      return
    }
    let value = scope.get(words[1])
    match value {
      None => out(words[1] + " -> (nothing)")
      Some(v) => out(words[1] + " -> " + v)
    }
    return
  }
  if verb == "del" || verb == "delete" {
    if words.length() < 2 {
      warn("del needs a key")
      return
    }
    if scope.delete(words[1]) {
      out("forgot " + words[1])
    } else {
      out(words[1] + " -> (nothing to forget)")
    }
    return
  }
  if verb == "touch" {
    if words.length() < 2 {
      warn("touch needs a key")
      return
    }
    if scope.touch(words[1]) {
      out("refreshed " + words[1])
    } else {
      out(words[1] + " -> (nothing to refresh)")
    }
    return
  }
  if verb == "keys" {
    out(scope.keys().join(", "))
    return
  }
  if verb == "entries" {
    let now = m.now()
    for entry in scope.entries() {
      out("  " + entry.describe(now))
    }
    return
  }
  if verb == "search" {
    search(scope, words)
    return
  }
  if verb == "search-all" {
    search_all(m, words)
    return
  }
  if verb == "scopes" {
    let names = m.scopes()
    if names.length() == 0 {
      out("(no scopes hold anything)")
      return
    }
    out(names.join(", "))
    return
  }
  if verb == "sweep" {
    let gone = m.sweep()
    out("dropped " + gone.to_string() + " expired")
    return
  }
  if verb == "advance" {
    if words.length() < 2 {
      warn("advance needs a number of milliseconds")
      return
    }
    let ms = @tesseract.parse_int(words[1]).unwrap_or(0).to_int64()
    if m.advance(ms) {
      out("clock -> " + m.now().to_string() + "ms")
    } else {
      warn("the clock is the host's; it does not move on request")
    }
    return
  }
  if verb == "clear" {
    scope.clear()
    out("forgotten everything in " + scope.name())
    return
  }
  if verb == "clear-all" {
    m.clear()
    out("forgotten everything, in every scope")
    return
  }
  if verb == "stats" {
    let s = m.stats()
    out("scope     " + scope.name())
    out("size      " + scope.size().to_string())
    out("total     " + m.size().to_string() + " of " + m.capacity().to_string())
    out(bytes_line(m, ""))
    out("puts      " + s.puts.to_string())
    out("updates   " + s.updates.to_string())
    out("gets      " + s.gets.to_string())
    out("hits      " + s.hits.to_string())
    out("misses    " + s.misses.to_string())
    out("deletes   " + s.deletes.to_string())
    out("evictions " + s.evictions.to_string())
    out("expired   " + s.expirations.to_string())
    return
  }
  warn("unknown command: " + verb + " (try help)")
}

///|
/// `put <key> <value...> [--ttl MS] [--sliding] [--importance N]`
///
/// The value is the rest of the line with the flags taken out, so
/// `put greeting hello world --ttl 1000` stores `hello world`.
///
/// The **importance** is how much the entry counts in a search, in `(0, 1]`.
/// One is the default and the most an entry can count; a lower number counts
/// less, so the entry is found less strongly. The store refuses an
/// importance outside that range, and so does the shell — a person who typed
/// a flag deserves to be told, not to be given a different memory than they
/// asked for.
fn put(scope : @tesseract_memory.Scope, words : Array[String]) -> Unit {
  if words.length() < 2 {
    warn("put needs a key and a value")
    return
  }
  let key = words[1]
  let mut sliding = false
  let mut explicit_ms : Int64? = None
  let mut importance : Double? = None
  let value_parts : Array[String] = []
  let mut i = 2
  while i < words.length() {
    if words[i] == "--sliding" {
      sliding = true
    } else if words[i] == "--ttl" && i + 1 < words.length() {
      explicit_ms = Some(
        @tesseract.parse_int(words[i + 1]).unwrap_or(0).to_int64(),
      )
      i = i + 1
    } else if words[i] == "--importance" && i + 1 < words.length() {
      match @tesseract.parse_float(words[i + 1]) {
        Some(value) => importance = Some(value)
        None => {
          warn("the importance is not a number: " + words[i + 1])
          return
        }
      }
      i = i + 1
    } else {
      value_parts.push(words[i])
    }
    i = i + 1
  }
  let configured = scope.default_ttl()
  let ttl = match explicit_ms {
    Some(ms) =>
      if sliding {
        @tesseract_memory.ttl_sliding(ms)
      } else {
        @tesseract_memory.ttl_absolute(ms)
      }
    None =>
      if sliding {
        match configured {
          @tesseract_memory.Ttl::Never => @tesseract_memory.ttl_never()
          @tesseract_memory.Ttl::Absolute(ms) =>
            @tesseract_memory.ttl_sliding(ms)
          @tesseract_memory.Ttl::Sliding(ms) =>
            @tesseract_memory.ttl_sliding(ms)
        }
      } else {
        configured
      }
  }
  // A lifetime of nothing, or one in the past, is an entry that is dead on
  // arrival: the store refuses it, and so does the shell.
  if !ttl.is_valid() {
    warn("the lifetime must be at least one millisecond")
    return
  }
  let spec = match importance {
    None => @tesseract_memory.default_spec().with_ttl(ttl)
    Some(value) => {
      if value <= 0.0 || value > 1.0 {
        warn("the importance must be more than zero and at most one")
        return
      }
      @tesseract_memory.default_spec().with_ttl(ttl).with_importance(value)
    }
  }
  let value = value_parts.join(" ")
  if scope.put_spec(key, value, spec) {
    out(key + " -> " + value)
  } else {
    warn("could not store " + key)
  }
}

///|
/// `search <query...> [-k N]`
///
/// The query is the rest of the line, so `search red apple` looks for those
/// two words together rather than for the word "red".
fn search(scope : @tesseract_memory.Scope, words : Array[String]) -> Unit {
  if words.length() < 2 {
    warn("search needs a query")
    return
  }
  let (query, k) = query_and_k(words)
  let hits = scope.search(query, k)
  if hits.length() == 0 {
    out("(nothing like that)")
    return
  }
  for hit in hits {
    out(hit.key + "  " + format_score(hit.score) + "  " + hit.value)
  }
}

///|
/// `search-all <query...> [-k N]`
///
/// The same search over every scope, so each hit says which scope it is in —
/// a key is unique only within a scope, and without the scope the answer
/// cannot say which entry it found.
fn search_all(m : @tesseract_memory.Memory, words : Array[String]) -> Unit {
  if words.length() < 2 {
    warn("search-all needs a query")
    return
  }
  let (query, k) = query_and_k(words)
  let hits = m.search_all(query, k)
  if hits.length() == 0 {
    out("(nothing like that)")
    return
  }
  for hit in hits {
    out(
      hit.scope +
      "  " +
      hit.key +
      "  " +
      format_score(hit.score) +
      "  " +
      hit.value,
    )
  }
}

///|
/// The query and the limit from the words of a search command.
///
/// The query is the rest of the line, so `search red apple` looks for those
/// two words together rather than for the word "red".
fn query_and_k(words : Array[String]) -> (String, Int32) {
  let mut k = 3
  let query_parts : Array[String] = []
  let mut i = 1
  while i < words.length() {
    if words[i] == "-k" && i + 1 < words.length() {
      k = @tesseract.parse_int(words[i + 1]).unwrap_or(3)
      i = i + 1
    } else {
      query_parts.push(words[i])
    }
    i = i + 1
  }
  (query_parts.join(" "), k)
}
