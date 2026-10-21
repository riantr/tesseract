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
///
/// `--manual-clock` is what makes the TTL visible: nothing expires until the
/// clock is moved, so the demo shows the boundary rather than a race.

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
  out("")
  out("commands:")
  out("  put <key> <value...>      remember a value")
  out("  put <key> <value...> --ttl MS --sliding")
  out("  get <key>                 read a value")
  out("  del <key>                 forget a key")
  out("  touch <key>               refresh a key without reading it")
  out("  keys                      the live keys")
  out("  entries                   the live entries, with their ages")
  out("  search <query...> [-k N] the entries most like the query")
  out("  sweep                     drop what has expired")
  out("  stats                     what the memory has done")
  out("  advance <ms>              move a manual clock forward")
  out("  clear                     forget everything")
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
  out("7. the store, and what it did")
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
    commands.push(a)
    i = i + 1
  }
  if commands.length() == 0 {
    print_help()
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
  let mut k = 0
  while k < commands.length() {
    run(m, commands[k])
    k = k + 1
  }
}

///|
/// One command.
fn run(m : @tesseract_memory.Memory, command : String) -> Unit {
  let words = split_ws(command)
  if words.length() == 0 {
    return
  }
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
    put(m, words)
    return
  }
  if verb == "get" {
    if words.length() < 2 {
      warn("get needs a key")
      return
    }
    let value = m.get(words[1])
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
    if m.delete(words[1]) {
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
    if m.touch(words[1]) {
      out("refreshed " + words[1])
    } else {
      out(words[1] + " -> (nothing to refresh)")
    }
    return
  }
  if verb == "keys" {
    out(m.keys().join(", "))
    return
  }
  if verb == "entries" {
    let now = m.now()
    for entry in m.entries() {
      out("  " + entry.describe(now))
    }
    return
  }
  if verb == "search" {
    search(m, words)
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
    m.clear()
    out("forgotten everything")
    return
  }
  if verb == "stats" {
    let s = m.stats()
    out("size      " + m.size().to_string() + " of " + m.capacity().to_string())
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
/// `put <key> <value...> [--ttl MS] [--sliding]`
///
/// The value is the rest of the line with the flags taken out, so
/// `put greeting hello world --ttl 1000` stores `hello world`.
fn put(m : @tesseract_memory.Memory, words : Array[String]) -> Unit {
  if words.length() < 2 {
    warn("put needs a key and a value")
    return
  }
  let key = words[1]
  let mut sliding = false
  let mut explicit_ms : Int64? = None
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
    } else {
      value_parts.push(words[i])
    }
    i = i + 1
  }
  let configured = m.config().default_ttl
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
  let value = value_parts.join(" ")
  if m.put_with_ttl(key, value, ttl) {
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
fn search(m : @tesseract_memory.Memory, words : Array[String]) -> Unit {
  if words.length() < 2 {
    warn("search needs a query")
    return
  }
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
  let query = query_parts.join(" ")
  let hits = m.search(query, k)
  if hits.length() == 0 {
    out("(nothing like that)")
    return
  }
  for hit in hits {
    out(hit.key + "  " + format_score(hit.score) + "  " + hit.value)
  }
}
