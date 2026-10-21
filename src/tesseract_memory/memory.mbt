///|
/// A short-term memory: entries that expire, a capacity the caller sets, and
/// retrieval by similarity.
///
/// This is a different shape of store from the core one, and the difference is
/// not cosmetic. The core is durable: a cell keeps its record until somebody
/// deletes it, the lattice's cell count is the bound, and overfilling it is an
/// error. A memory is the tier *above* that: an entry has a deadline, the
/// bound is a number the caller sets, and going over it evicts an entry by a
/// named policy rather than refusing the write.
///
/// The two rules that everything else follows from:
///
/// - **The path belongs to the statement** — nothing. That rule was about SQL;
///   here the rules are about who owns time and who owns space.
/// - **Expiry is eager.** Every operation that observes the clock first
///   removes what has expired, so the store never holds a dead entry, `size`
///   is the number of *live* entries, and a caller never has to wonder
///   whether a zero it read was a missing key or an expired one.
///
/// The clock is a value, not a call, for the reason the core's clock is: a test
/// that reads the host clock cannot assert that something has not happened yet.
/// `Manual` only moves when the caller says so.
pub struct Memory {
  entries : Map[String, Entry]
  mut clock : MemoryClock
  mut config : Config
  stats : Stats
}

///|
/// The largest `Int64`, used as the eviction rank of an entry that never
/// expires.
///
/// Under `SoonestExpiry` an entry with no deadline is infinitely far from
/// expiring, so it has to sort after every entry that has one. A deadline
/// cannot exceed this value, so it sorts after those too.
const NEVER_EXPIRES : Int64 = 9223372036854775807L

///|
/// How a memory behaves.
///
/// Built with the `with_*` methods rather than by filling in fields, because a
/// `Config` has five settings and every one of them has a sensible default.
pub struct Config {
  capacity : Int32
  default_ttl : Ttl
  eviction : EvictionPolicy
  similarity : Similarity
  recency : Recency
}

///|
/// What a memory has done.
///
/// The counters are there because "the memory is working" is not a thing you
/// can see; these are. `hits` and `misses` say what the store was asked for
/// and what it had, `evictions` says what it gave up to make room, and
/// `expirations` says what it dropped because its time was up.
pub struct Stats {
  mut puts : Int64
  mut updates : Int64
  mut gets : Int64
  mut hits : Int64
  mut misses : Int64
  mut deletes : Int64
  mut evictions : Int64
  mut expirations : Int64
}

///|
/// The default configuration: a hundred entries, no expiry, LRU eviction,
/// Jaccard similarity, and no recency weighting.
pub fn default_config() -> Config {
  {
    capacity: 100,
    default_ttl: ttl_never(),
    eviction: evict_lru(),
    similarity: similarity_jaccard(),
    recency: recency_none(),
  }
}

///|
/// The same configuration with a different capacity.
pub fn Config::with_capacity(self : Config, capacity : Int32) -> Config {
  { ..self, capacity, }
}

///|
/// The same configuration with a different default TTL.
pub fn Config::with_default_ttl(self : Config, ttl : Ttl) -> Config {
  { ..self, default_ttl: ttl, }
}

///|
/// The same configuration with a different eviction policy.
pub fn Config::with_eviction(
  self : Config,
  eviction : EvictionPolicy,
) -> Config {
  { ..self, eviction, }
}

///|
/// The same configuration with a different similarity.
pub fn Config::with_similarity(
  self : Config,
  similarity : Similarity,
) -> Config {
  { ..self, similarity, }
}

///|
/// The same configuration with a different recency policy.
pub fn Config::with_recency(self : Config, recency : Recency) -> Config {
  { ..self, recency, }
}

///|
/// A memory holding at most `capacity` live entries, on the host clock.
pub fn new_memory(capacity : Int32) -> Memory {
  new_memory_with(default_config().with_capacity(capacity))
}

///|
/// A memory with a full configuration, on the host clock.
pub fn new_memory_with(config : Config) -> Memory {
  {
    entries: Map([]),
    clock: memory_clock_system(),
    config,
    stats: {
      puts: 0L,
      updates: 0L,
      gets: 0L,
      hits: 0L,
      misses: 0L,
      deletes: 0L,
      evictions: 0L,
      expirations: 0L,
    },
  }
}

///|
/// A memory with a full configuration, on a clock the caller controls.
pub fn new_memory_with_clock(config : Config, clock : MemoryClock) -> Memory {
  let m = new_memory_with(config)
  m.clock = clock
  m
}

///|
/// The configuration in force.
pub fn Memory::config(self : Memory) -> Config {
  self.config
}

///|
/// Replace the configuration.
///
/// A capacity of zero or less is refused and the old configuration is kept: a
/// memory that cannot hold anything is not a memory, and silently becoming one
/// would lose the caller's entries on the next write.
pub fn Memory::set_config(self : Memory, config : Config) -> Bool {
  if config.capacity <= 0 {
    return false
  }
  self.config = config
  true
}

///|
/// The clock in force.
pub fn Memory::clock(self : Memory) -> MemoryClock {
  self.clock
}

///|
/// The current instant, in milliseconds since the Unix epoch.
pub fn Memory::now(self : Memory) -> Int64 {
  self.clock.read()
}

///|
/// Move a manual clock forward by `ms`.
///
/// Returns false for a `System` clock, which does not move because it is the
/// host's. Moving it by hand would make the memory's idea of time disagree
/// with the timestamps it writes.
pub fn Memory::advance(self : Memory, ms : Int64) -> Bool {
  match self.clock {
    System => false
    Manual(now) => {
      self.clock = Manual(now + ms)
      true
    }
  }
}

///|
/// Remove every entry whose time is up, and say how many went.
///
/// Expiry is eager, so this is normally already done by the time it is called;
/// it is here so a caller can ask, and so the count lands in the statistics on
/// purpose rather than by accident.
pub fn Memory::sweep(self : Memory) -> Int64 {
  self.expire_due()
}

///|
/// How many entries are live.
///
/// Expired entries do not count: they are gone the moment their time is up,
/// whether or not anything has swept for them yet.
pub fn Memory::size(self : Memory) -> Int32 {
  ignore(self.expire_due())
  self.entries.length()
}

///|
/// The most entries this memory will hold.
pub fn Memory::capacity(self : Memory) -> Int32 {
  self.config.capacity
}

///|
/// Write a value under a key, with the default TTL.
///
/// A `put` of a key that is already there replaces the value **in place** and
/// evicts nothing — overwriting a key must not cost another key its place.
/// The replacement is a new entry: it was added now, and nobody has read the
/// new value yet, so its hit count starts at zero.
pub fn Memory::put(self : Memory, key : String, value : String) -> Bool {
  self.put_with_ttl(key, value, self.config.default_ttl)
}

///|
/// Write a value under a key, with a TTL of this entry's own.
///
/// A key that is already there is replaced in place, and only a *new* key can
/// push the store over its capacity.
pub fn Memory::put_with_ttl(
  self : Memory,
  key : String,
  value : String,
  ttl : Ttl,
) -> Bool {
  ignore(self.expire_due())
  let now = self.now()
  let (deadline, sliding) = ttl.deadline(now)
  let window = ttl.window_ms()
  let already = self.entries.contains(key)
  if !already && self.entries.length() >= self.config.capacity {
    match self.pick_victim() {
      Some(victim) => {
        self.entries.remove(victim)
        self.stats.evictions = self.stats.evictions + 1L
      }
      None => return false
    }
  }
  self.entries.set(key, {
    key,
    value,
    added_at: now,
    deadline,
    window_ms: window,
    sliding,
    last_seen: now,
    hits: 0L,
  })
  self.stats.puts = self.stats.puts + 1L
  if already {
    self.stats.updates = self.stats.updates + 1L
  }
  true
}

///|
/// Read a value, and count it as a use.
///
/// A hit touches the entry: the idle clock restarts, the hit count goes up,
/// and a sliding entry's deadline moves forward. A miss counts as a miss and
/// touches nothing.
pub fn Memory::get(self : Memory, key : String) -> String? {
  ignore(self.expire_due())
  self.stats.gets = self.stats.gets + 1L
  match self.entries.get(key) {
    None => {
      self.stats.misses = self.stats.misses + 1L
      None
    }
    Some(entry) => {
      self.entries.set(key, entry.touched(self.now()))
      self.stats.hits = self.stats.hits + 1L
      Some(entry.value)
    }
  }
}

///|
/// Whether a key is live.
///
/// An expired key is not present, and saying otherwise would make `contains`
/// and `get` disagree.
pub fn Memory::contains(self : Memory, key : String) -> Bool {
  ignore(self.expire_due())
  self.entries.contains(key)
}

///|
/// Refresh an entry without reading it.
///
/// This is what a sliding TTL is for, and it is also how a caller says "this is
/// still relevant" about something it did not read. Returns false when the key
/// is not there.
pub fn Memory::touch(self : Memory, key : String) -> Bool {
  ignore(self.expire_due())
  match self.entries.get(key) {
    None => false
    Some(entry) => {
      self.entries.set(key, entry.touched(self.now()))
      true
    }
  }
}

///|
/// Forget a key.
///
/// Returns false when there was nothing to forget.
pub fn Memory::delete(self : Memory, key : String) -> Bool {
  ignore(self.expire_due())
  let removed = self.entries.remove_and_get(key)
  match removed {
    None => false
    Some(_) => {
      self.stats.deletes = self.stats.deletes + 1L
      true
    }
  }
}

///|
/// The live keys, in order.
pub fn Memory::keys(self : Memory) -> Array[String] {
  ignore(self.expire_due())
  let out : Array[String] = []
  for k in self.entries.keys() {
    out.push(k)
  }
  sort_strings(out)
  out
}

///|
/// The live entries, in key order.
pub fn Memory::entries(self : Memory) -> Array[Entry] {
  ignore(self.expire_due())
  let out : Array[Entry] = []
  for (_, entry) in self.entries.iter() {
    out.push(entry)
  }
  out.sort_by(fn(a, b) { String::compare(a.key, b.key) })
  out
}

///|
/// One entry, by key.
pub fn Memory::entry(self : Memory, key : String) -> Entry? {
  ignore(self.expire_due())
  self.entries.get(key)
}

///|
/// Forget everything.
///
/// The statistics are not reset: a memory that has served two thousand
/// requests and was then cleared has still served two thousand requests.
pub fn Memory::clear(self : Memory) -> Unit {
  self.entries.clear()
}

///|
/// What the memory has done.
pub fn Memory::stats(self : Memory) -> Stats {
  self.stats
}

///|
/// Remove every entry whose time is up, and say how many went.
fn Memory::expire_due(self : Memory) -> Int64 {
  let now = self.now()
  let dead : Array[String] = []
  for (k, entry) in self.entries.iter() {
    if entry.expired(now) {
      dead.push(k)
    }
  }
  let mut gone = 0L
  for k in dead {
    self.entries.remove(k)
    gone = gone + 1L
  }
  self.stats.expirations = self.stats.expirations + gone
  gone
}

///|
/// The entry the policy would evict, or `None` when there is nothing to evict.
///
/// The tie-break is the key, so the same sequence of operations always evicts
/// the same entry. A store that evicts differently on two runs of the same
/// program is a store nobody can test.
fn Memory::pick_victim(self : Memory) -> String? {
  let mut best : String? = None
  let mut best_rank = 0L
  for (k, entry) in self.entries.iter() {
    let rank = match self.config.eviction {
      LeastRecentlyUsed => entry.last_seen
      LeastFrequentlyUsed => entry.hits
      SoonestExpiry =>
        if entry.deadline == 0L {
          NEVER_EXPIRES
        } else {
          entry.deadline
        }
      OldestFirst => entry.added_at
    }
    match best {
      None => {
        best = Some(k)
        best_rank = rank
      }
      Some(current) =>
        if rank < best_rank ||
          (rank == best_rank && String::compare(k, current) < 0) {
          best = Some(k)
          best_rank = rank
        }
    }
  }
  best
}

///|
/// Sort strings by their byte order.
fn sort_strings(items : Array[String]) -> Unit {
  items.sort_by(fn(a, b) { String::compare(a, b) })
}
