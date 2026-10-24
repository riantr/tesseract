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
/// The three rules that everything else follows from:
///
/// - **Expiry is eager.** Every operation that observes the clock first
///   removes what has expired, so the store never holds a dead entry, `size`
///   is the number of *live* entries, and a caller never has to wonder
///   whether a zero it read was a missing key or an expired one.
/// - **The keys live in scopes.** A scope is a named partition of the
///   keyspace, and a key belongs to exactly one of them: `default` and
///   `notes` can both hold a key called `todo` without either of them seeing
///   the other's entry. The scopes of one memory share its clock, its budget
///   and its statistics.
/// - **The limits are the store's, not a scope's.** The capacity and the byte
///   budget are spent across every scope, and the eviction that follows a
///   write can take an entry from any of them. A scope is a partition of one
///   pool, not a pool of its own.
///
/// The clock is a value, not a call, for the reason the core's clock is: a test
/// that reads the host clock cannot assert that something has not happened yet.
/// `Manual` only moves when the caller says so.
///
/// The fields are **private**. A `Map` is mutable in place, so a public field
/// would let a caller remove an entry behind the store's back — and the byte
/// total, which is a running count of the values, would then be counting
/// something that is no longer there. The limits a memory enforces are only
/// worth anything if the store cannot be edited behind its own back.
pub struct Memory {
  priv entries : Map[String, Map[String, Entry]]
  priv mut bytes : Int64
  priv mut clock : MemoryClock
  priv mut config : Config
  priv stats : Stats
}

///|
/// The name of the scope a memory's own methods address.
///
/// A memory that is never told about scopes still has one — this one — and
/// everything written through the memory itself lands there. A caller that
/// wants a partition asks for it by name.
pub fn default_scope_name() -> String {
  "default"
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
/// `Config` has six settings and every one of them has a sensible default.
pub struct Config {
  capacity : Int32
  max_bytes : Int64
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
///
/// The counters are the **store's**: a write into one scope and a read out of
/// another are both counted here, because there is one store behind them.
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
/// The default configuration: a hundred entries, no byte budget, no expiry,
/// LRU eviction, Jaccard similarity, and no recency weighting.
pub fn default_config() -> Config {
  {
    capacity: 100,
    max_bytes: 0L,
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
/// The same configuration with a different byte budget.
///
/// A budget of zero means no limit. The budget counts the **values** in UTF-8
/// bytes, so it is the size of what the memory holds rather than the number of
/// things it holds — the two are different limits and a caller may want both.
///
/// The budget is the **store's**: it covers the values of every scope, so a
/// write into one scope can be refused for the room another scope is taking.
pub fn Config::with_max_bytes(self : Config, max_bytes : Int64) -> Config {
  { ..self, max_bytes, }
}

///|
/// True when this configuration is one a memory can honour.
///
/// Two settings are not: a capacity of zero or less, and a negative byte
/// budget. A memory that can hold nothing is not a memory, and a negative
/// budget is a mistake that would otherwise read as the one value that means
/// no limit at all.
pub fn Config::is_valid(self : Config) -> Bool {
  self.capacity > 0 && self.max_bytes >= 0L
}

///|
/// The configuration a memory can actually hold.
///
/// A setting the memory cannot honour is replaced — a capacity of zero or
/// less falls back to the default capacity, and a negative budget falls back
/// to no budget — and the rest of the configuration is kept, because only the
/// impossible setting is the caller's mistake.
///
/// A **new** memory sanitises rather than refuses, because it has no entries
/// to protect: a memory that silently became unable to hold anything would
/// lose nothing, since there is nothing in it yet. A memory that is already
/// running **refuses** an invalid configuration and keeps the old one, for
/// the same reason: there are entries in it, and a limit that changed under
/// them would throw them away.
fn usable(config : Config) -> Config {
  {
    ..config,
    capacity: if config.capacity > 0 {
      config.capacity
    } else {
      default_config().capacity
    },
    max_bytes: if config.max_bytes >= 0L {
      config.max_bytes
    } else {
      0L
    },
  }
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
///
/// A setting the memory cannot honour is replaced rather than refused — see
/// `usable`. `Config::is_valid` says whether a configuration is one a memory
/// can hold, and the memory's own `capacity` and `max_bytes` say what it
/// ended up with.
pub fn new_memory_with(config : Config) -> Memory {
  new_memory_with_clock(config, memory_clock_system())
}

///|
/// A memory with a full configuration, on a clock the caller controls.
pub fn new_memory_with_clock(config : Config, clock : MemoryClock) -> Memory {
  {
    entries: Map([]),
    bytes: 0L,
    clock,
    config: usable(config),
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
///
/// A negative byte budget is refused for the same reason. Zero is the way to
/// say "no budget", and a negative number is a mistake that would otherwise
/// read as the one value that means no limit at all — so it is turned away
/// rather than taken as permission to keep everything.
///
/// Lowering a limit does **not** evict on the spot. The store is brought back
/// within its new limits by the next write that has to make room; until then
/// `size_bytes` can be larger than `max_bytes`, and that is the honest report
/// of a store that is over its budget.
pub fn Memory::set_config(self : Memory, config : Config) -> Bool {
  if config.capacity <= 0 {
    return false
  }
  if config.max_bytes < 0L {
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
///
/// Reading the clock is reading the store's state, so this removes what has
/// expired first: the instant is reported, and the store is not holding
/// anything that is already gone.
pub fn Memory::now(self : Memory) -> Int64 {
  ignore(self.expire_due())
  self.clock.read()
}

///|
/// Move a manual clock forward by `ms`.
///
/// Returns false for a `System` clock, which does not move because it is the
/// host's. Moving it by hand would make the memory's idea of time disagree
/// with the timestamps it writes.
///
/// A negative interval is refused as well. A clock that runs backwards is not
/// a clock, and an entry would then be *older* than the moment it was
/// written — which makes the recency weight larger than one, and the search
/// score larger than the `0.0..1.0` it is documented to be in.
///
/// An interval so large that the clock would pass the end of what an `Int64`
/// can hold is refused for the same reason. The arithmetic would wrap round
/// into the past, and the clock would run backwards by nine hundred million
/// years while reporting that it had moved forwards.
pub fn Memory::advance(self : Memory, ms : Int64) -> Bool {
  if ms < 0L {
    return false
  }
  match self.clock {
    System => false
    Manual(now) => {
      if now > MAX_INSTANT - ms {
        return false
      }
      self.clock = Manual(now + ms)
      true
    }
  }
}

///|
/// Remove every entry whose time is up, in every scope, and say how many went.
///
/// Expiry is eager, so this is normally already done by the time it is called;
/// it is here so a caller can ask, and so the count lands in the statistics on
/// purpose rather than by accident.
pub fn Memory::sweep(self : Memory) -> Int64 {
  self.expire_due()
}

///|
/// How many entries are live, in every scope.
///
/// Expired entries do not count: they are gone the moment their time is up,
/// whether or not anything has swept for them yet.
///
/// This is the **store's** count, and it is the one to compare with
/// `capacity`: the capacity is spent across the scopes, so the store is full
/// when this reaches it. `Scope::size` is the count of one scope, and
/// `Memory::keys` lists the **default** scope's keys — so the store's count
/// and the default scope's key list are not the same number once a second
/// scope holds something.
pub fn Memory::size(self : Memory) -> Int32 {
  ignore(self.expire_due())
  self.entry_count()
}

///|
/// The most entries this memory will hold.
pub fn Memory::capacity(self : Memory) -> Int32 {
  self.config.capacity
}

///|
/// Write a value under a key, with the default TTL.
///
/// The key goes into the **default scope**, so `put` and `get` on the memory
/// itself are the same scope talking to itself.
///
/// The entry counts fully — the default importance — and lives as long as the
/// store's default TTL says.
///
/// A `put` of a key that is already there replaces the value **in place** and
/// evicts nothing — overwriting a key must not cost another key its place.
/// The replacement is a new entry: it was added now, and nobody has read the
/// new value yet, so its hit count starts at zero.
pub fn Memory::put(self : Memory, key : String, value : String) -> Bool {
  self.put_spec(key, value, default_spec().with_ttl(self.config.default_ttl))
}

///|
/// Write a value under a key, with a TTL of this entry's own.
///
/// A key that is already there is replaced in place, and only a *new* key can
/// push the store over its **capacity**: overwriting one replaces a value and
/// does not grow the number of entries.
///
/// The byte budget is a different limit, and a replacement can push the store
/// over it — a five-byte value replaced by a two-hundred-byte one is two
/// hundred and five bytes of content, not five. So a replacement makes room
/// too, when it has to, and it evicts **other** entries: the key being written
/// is never the one thrown away to make room for itself.
///
/// The room it makes is made out of the **store**, not out of this scope: the
/// eviction that follows can take an entry from any scope.
///
/// A lifetime in the past is **refused**: an entry written with one is dead
/// the moment it is written, and accepting the write would be accepting a
/// write that does nothing. The refusal leaves the store as it was.
pub fn Memory::put_with_ttl(
  self : Memory,
  key : String,
  value : String,
  ttl : Ttl,
) -> Bool {
  self.put_spec(key, value, default_spec().with_ttl(ttl))
}

///|
/// Write a value under a key, with a spec of this entry's own.
///
/// The spec carries the two things an entry is written with: how long it
/// lives, and how much it counts. `put` and `put_with_ttl` are the two
/// shorthands for the common cases.
///
/// A spec the store cannot honour is **refused**, and the refusal leaves the
/// store as it was: a write that fails must not cost the caller the entries
/// it already has. See `EntrySpec::is_valid` for what "cannot honour" means.
pub fn Memory::put_spec(
  self : Memory,
  key : String,
  value : String,
  spec : EntrySpec,
) -> Bool {
  self.put_in(default_scope_name(), key, value, spec)
}

///|
/// How many bytes the stored content takes up, in every scope.
///
/// UTF-8 bytes, because that is the unit a budget is stated in. The content is
/// the values **and** the labels that go with them — the budget is about what
/// the memory holds, and a label is something the memory holds. The keys are
/// not counted: they are the name of an entry rather than its content, and the
/// number of keys is bounded by the capacity.
///
/// This is the **store's** total, because the budget is the store's — it is
/// the number to compare with `max_bytes`.
pub fn Memory::size_bytes(self : Memory) -> Int64 {
  ignore(self.expire_due())
  self.bytes
}

///|
/// The byte budget in force. Zero means no limit.
pub fn Memory::max_bytes(self : Memory) -> Int64 {
  self.config.max_bytes
}

///|
/// Evicts until a write of `total_bytes` would fit, or reports that it cannot.
///
/// Two limits, and the store has to satisfy **both**: at most `capacity`
/// entries, and at most `max_bytes` of content. A caller who sets both gets
/// the smaller of the two, which is the point of setting both.
///
/// The question is asked of the store as it will be **after** the write, not
/// as it is now: the key's own old content is subtracted, because the write
/// replaces it. Asking about the present would make every replacement look
/// like an addition, and a store that evicts on a replacement is a store that
/// throws away a memory the caller did not ask to lose.
///
/// The key being written is **never** the victim. Evicting it to make room
/// for itself would be work done twice — the entry would be thrown away and
/// then written again — and it would take the store's byte total with it, so
/// the arithmetic would be counting a value that is no longer there.
///
/// A **pinned** entry is never the victim either, and that makes a store of
/// nothing but pinned entries a store that cannot make room for anything. So
/// the room is **planned before it is taken**: if even throwing away every
/// entry that could be thrown away would not make room, the write is refused
/// and **nothing is evicted**. A refused write that had already thrown
/// something away would cost the caller an entry it did not ask to lose.
fn Memory::make_room(
  self : Memory,
  scope : String,
  key : String,
  total_bytes : Int64,
  new_key : Bool,
) -> Bool {
  if !self.can_make_room(scope, key, total_bytes, new_key) {
    return false
  }
  let mut ok = true
  while self.over_capacity_after(scope, key, total_bytes, new_key) {
    match self.pick_victim(scope, key) {
      Some(victim) => {
        ignore(self.forget(victim.0, victim.1))
        self.stats.evictions = self.stats.evictions + 1L
      }
      None => {
        ok = false
        break
      }
    }
  }
  ok
}

///|
/// Whether the write could fit at all.
///
/// The best case is that **every** entry which could be thrown away is thrown
/// away, and the question is whether the store would fit then. If it would
/// not, the write cannot be made room for, and it is refused before anything
/// is evicted.
///
/// The entries that could be thrown away are the ones that are **not pinned**
/// and not the key being written — a pinned entry is never a victim, and the
/// key being written is never thrown away to make room for itself.
fn Memory::can_make_room(
  self : Memory,
  scope : String,
  key : String,
  total_bytes : Int64,
  new_key : Bool,
) -> Bool {
  let mut evictable = 0
  let mut evictable_bytes = 0L
  for (other_scope, inner) in self.entries.iter() {
    for (other_key, entry) in inner.iter() {
      if other_scope == scope && other_key == key {
        continue
      }
      if entry.pinned {
        continue
      }
      evictable = evictable + 1
      evictable_bytes = evictable_bytes + entry_bytes(entry)
    }
  }
  // The count, if every one of them went.
  let final_count = self.entry_count() -
    evictable +
    (if new_key { 1 } else { 0 })
  if final_count > self.config.capacity {
    return false
  }
  if self.config.max_bytes > 0L {
    // The bytes, if every one of them went. The key being written is not
    // among them, so its own old content is subtracted on its own.
    let old_bytes = match self.lookup(scope, key) {
      Some(old) => entry_bytes(old)
      None => 0L
    }
    let final_bytes = self.bytes - evictable_bytes - old_bytes + total_bytes
    if final_bytes > self.config.max_bytes {
      return false
    }
  }
  true
}

///|
/// True when the store, as it will be after this write, is over either limit.
///
/// The count only grows for a new key, so only a new key can be over the
/// capacity. The byte total grows for a replacement too, and the question
/// there is whether the store will fit **after** the old value is gone and
/// the new one is in.
fn Memory::over_capacity_after(
  self : Memory,
  scope : String,
  key : String,
  total_bytes : Int64,
  new_key : Bool,
) -> Bool {
  if new_key && self.entry_count() + 1 > self.config.capacity {
    return true
  }
  if self.config.max_bytes > 0L {
    let final_bytes = match self.lookup(scope, key) {
      Some(old) => self.bytes - entry_bytes(old) + total_bytes
      None => self.bytes + total_bytes
    }
    if final_bytes > self.config.max_bytes {
      return true
    }
  }
  false
}

///|
/// How many bytes an entry takes up: its value and its labels.
///
/// The budget is about what the memory holds, and this is what it holds. The
/// key and the scope are not counted — they are the **name** of the entry
/// rather than its content, and the capacity bounds how many entries there
/// are.
fn entry_bytes(entry : Entry) -> Int64 {
  utf8_bytes(entry.value) + entry.metadata.bytes()
}

///|
/// The number of live entries, over every scope.
fn Memory::entry_count(self : Memory) -> Int32 {
  let mut total = 0
  for (_, inner) in self.entries.iter() {
    total = total + inner.length()
  }
  total
}

///|
/// Writes an entry, keeping the byte total right.
///
/// Every write goes through here, and so does every removal, so the total
/// cannot drift: a write subtracts whatever the key was holding before and
/// adds what it holds now, and a removal subtracts what it held.
fn Memory::write(
  self : Memory,
  scope : String,
  key : String,
  entry : Entry,
) -> Unit {
  match self.entries.get(scope) {
    Some(inner) => {
      match inner.get(key) {
        Some(old) => self.bytes = self.bytes - entry_bytes(old)
        None => ()
      }
      inner.set(key, entry)
      self.bytes = self.bytes + entry_bytes(entry)
    }
    None => {
      let inner : Map[String, Entry] = Map([])
      inner.set(key, entry)
      self.entries.set(scope, inner)
      self.bytes = self.bytes + entry_bytes(entry)
    }
  }
}

///|
/// Removes an entry, keeping the byte total right.
///
/// A scope whose last entry goes is dropped with it, so a scope that holds
/// nothing is not a scope the store still knows about.
fn Memory::forget(self : Memory, scope : String, key : String) -> Bool {
  match self.entries.get(scope) {
    None => false
    Some(inner) =>
      match inner.remove_and_get(key) {
        None => false
        Some(entry) => {
          self.bytes = self.bytes - entry_bytes(entry)
          if inner.length() == 0 {
            ignore(self.entries.remove_and_get(scope))
          }
          true
        }
      }
  }
}

///|
/// The entry stored under a key in a scope, or `None`.
fn Memory::lookup(self : Memory, scope : String, key : String) -> Entry? {
  match self.entries.get(scope) {
    Some(inner) => inner.get(key)
    None => None
  }
}

///|
/// Read a value, and count it as a use.
///
/// A hit touches the entry: the idle clock restarts, the hit count goes up,
/// and a sliding entry's deadline moves forward. A miss counts as a miss and
/// touches nothing.
pub fn Memory::get(self : Memory, key : String) -> String? {
  self.get_in(default_scope_name(), key)
}

///|
/// Whether a key is live.
///
/// An expired key is not present, and saying otherwise would make `contains`
/// and `get` disagree.
pub fn Memory::contains(self : Memory, key : String) -> Bool {
  self.contains_in(default_scope_name(), key)
}

///|
/// Refresh an entry without reading it.
///
/// This is what a sliding TTL is for, and it is also how a caller says "this is
/// still relevant" about something it did not read. Returns false when the key
/// is not there.
pub fn Memory::touch(self : Memory, key : String) -> Bool {
  self.touch_in(default_scope_name(), key)
}

///|
/// Pin an entry, so it is never evicted to make room for another one.
///
/// A pinned entry is not a candidate for eviction at all: not the oldest, not
/// the least used, not the one whose time is up soonest. The pin is absolute
/// — a store that broke it when it had to would make the promise depend on
/// the state of the store — and a store that cannot make room for a write
/// without breaking a pin **refuses the write** instead, and leaves the store
/// as it was.
///
/// The pin says nothing about expiry: a pinned entry with a lifetime still
/// dies when its time is up.
///
/// The pin is the only thing that changes. The entry keeps its age, its hit
/// count, its deadline and its labels, because pinning something is not the
/// same as reading it. Returns false when the key is not there.
pub fn Memory::pin(self : Memory, key : String) -> Bool {
  self.pin_in(default_scope_name(), key, true)
}

///|
/// Unpin an entry, so it can be evicted again.
///
/// Everything else about the entry is left as it was, for the same reason
/// pinning does not change anything else. Returns false when the key is not
/// there.
pub fn Memory::unpin(self : Memory, key : String) -> Bool {
  self.pin_in(default_scope_name(), key, false)
}

///|
/// Forget a key.
///
/// Returns false when there was nothing to forget.
pub fn Memory::delete(self : Memory, key : String) -> Bool {
  self.delete_in(default_scope_name(), key)
}

///|
/// The live keys of the default scope, in order.
pub fn Memory::keys(self : Memory) -> Array[String] {
  self.keys_in(default_scope_name())
}

///|
/// The live entries of the default scope, in key order.
pub fn Memory::entries(self : Memory) -> Array[Entry] {
  self.entries_in(default_scope_name())
}

///|
/// One entry, by key, from the default scope.
pub fn Memory::entry(self : Memory, key : String) -> Entry? {
  self.entry_in(default_scope_name(), key)
}

///|
/// Forget everything, in every scope.
///
/// The statistics are not reset: a memory that has served two thousand
/// requests and was then cleared has still served two thousand requests.
///
/// This is the **store's** reset, not a scope's: `Scope::clear` forgets one
/// scope and leaves the others alone.
pub fn Memory::clear(self : Memory) -> Unit {
  self.entries.clear()
  self.bytes = 0L
}

///|
/// What the memory has done.
pub fn Memory::stats(self : Memory) -> Stats {
  self.stats
}

///|
/// Write a value under a key, in a scope, with a spec.
///
/// The scope-aware form of `put_spec`, and the only place a write actually
/// happens.
fn Memory::put_in(
  self : Memory,
  scope : String,
  key : String,
  value : String,
  spec : EntrySpec,
) -> Bool {
  // A spec the store cannot honour is refused before anything is touched, so
  // the refusal leaves the store exactly as it was.
  if !spec.is_valid() {
    return false
  }
  ignore(self.expire_due())
  let now = self.now()
  let (deadline, sliding) = spec.ttl.deadline(now)
  let window = spec.ttl.window_ms()
  // The content of an entry is its value **and** its labels: the budget is
  // about what the memory holds, and this is what it will hold.
  let total_bytes = utf8_bytes(value) + spec.metadata.bytes()
  // Content that cannot fit in an *empty* store is refused here, before
  // anything is evicted. Refusing it later would cost the caller every entry
  // it already has, and a write that fails should not empty the memory.
  if self.config.max_bytes > 0L && total_bytes > self.config.max_bytes {
    return false
  }
  let already = self.lookup(scope, key) is Some(_)
  if !self.make_room(scope, key, total_bytes, !already) {
    return false
  }
  self.write(scope, key, {
    scope,
    key,
    value,
    added_at: now,
    deadline,
    window_ms: window,
    sliding,
    last_seen: now,
    hits: 0L,
    importance: spec.importance,
    metadata: spec.metadata,
    pinned: spec.pinned,
  })
  self.stats.puts = self.stats.puts + 1L
  if already {
    self.stats.updates = self.stats.updates + 1L
  }
  true
}

///|
/// Put an entry back exactly as it was.
///
/// A `put` builds a **new** entry: it stamps the time, it counts the hits from
/// zero, and it turns a lifetime into a deadline measured from now. That is
/// right for a write and wrong for a restore — a store that is reloaded wants
/// the entry it had, not a copy of it with a new age.
///
/// So this takes the entry itself, and the entry's own fields are what the
/// store keeps: the deadline it had, the time it was added, how often it was
/// read, and when it was last seen. A store that reloads through this keeps
/// its LRU and LFU ranking across the restart, which is the whole point of
/// restoring rather than re-writing.
///
/// The limits are the store's, exactly as they are for a write: the entry
/// still has to fit the byte budget, and the capacity is still the capacity.
/// A restore that cannot make room is refused the same way a write is — and a
/// refused restore leaves the store as it was.
///
/// An entry whose time is already up is **refused**. It is dead, and accepting
/// it would be accepting a write that does nothing.
///
/// Returns false when the entry was refused, or when there is nothing to
/// restore — an entry with no key has no name to be stored under.
pub fn Memory::restore_entry(self : Memory, entry : Entry) -> Bool {
  if entry.key == "" {
    return false
  }
  if entry.importance <= 0.0 || entry.importance > 1.0 {
    return false
  }
  if !entry.metadata.is_valid() {
    return false
  }
  ignore(self.expire_due())
  let now = self.now()
  // Whether an entry expires is decided by its window: a window of zero means
  // it never does, and its deadline is then only a number.
  if entry.window_ms > 0L && entry.deadline <= now {
    return false
  }
  let total_bytes = entry_bytes(entry)
  // Content that cannot fit in an empty store is refused before anything is
  // evicted, for the same reason a write refuses it: a failed write must not
  // cost the caller the entries it already has.
  if self.config.max_bytes > 0L && total_bytes > self.config.max_bytes {
    return false
  }
  let already = self.lookup(entry.scope, entry.key) is Some(_)
  if !self.make_room(entry.scope, entry.key, total_bytes, !already) {
    return false
  }
  self.write(entry.scope, entry.key, entry)
  self.stats.puts = self.stats.puts + 1L
  if already {
    self.stats.updates = self.stats.updates + 1L
  }
  true
}

///|
/// Read a value from a scope, and count it as a use.
fn Memory::get_in(self : Memory, scope : String, key : String) -> String? {
  ignore(self.expire_due())
  self.stats.gets = self.stats.gets + 1L
  match self.lookup(scope, key) {
    None => {
      self.stats.misses = self.stats.misses + 1L
      None
    }
    Some(entry) => {
      self.write(scope, key, entry.touched(self.now()))
      self.stats.hits = self.stats.hits + 1L
      Some(entry.value)
    }
  }
}

///|
/// Whether a key is live, in a scope.
fn Memory::contains_in(self : Memory, scope : String, key : String) -> Bool {
  ignore(self.expire_due())
  self.lookup(scope, key) is Some(_)
}

///|
/// Refresh an entry in a scope, without reading it.
fn Memory::touch_in(self : Memory, scope : String, key : String) -> Bool {
  ignore(self.expire_due())
  match self.lookup(scope, key) {
    None => false
    Some(entry) => {
      self.write(scope, key, entry.touched(self.now()))
      true
    }
  }
}

///|
/// Set the pin of an entry in a scope.
fn Memory::pin_in(
  self : Memory,
  scope : String,
  key : String,
  pinned : Bool,
) -> Bool {
  ignore(self.expire_due())
  match self.lookup(scope, key) {
    None => false
    Some(entry) => {
      self.write(scope, key, {
        scope: entry.scope,
        key: entry.key,
        value: entry.value,
        added_at: entry.added_at,
        deadline: entry.deadline,
        window_ms: entry.window_ms,
        sliding: entry.sliding,
        last_seen: entry.last_seen,
        hits: entry.hits,
        importance: entry.importance,
        metadata: entry.metadata,
        pinned,
      })
      true
    }
  }
}

///|
/// Forget a key in a scope.
fn Memory::delete_in(self : Memory, scope : String, key : String) -> Bool {
  ignore(self.expire_due())
  if self.forget(scope, key) {
    self.stats.deletes = self.stats.deletes + 1L
    true
  } else {
    false
  }
}

///|
/// One entry, by key, in a scope.
fn Memory::entry_in(self : Memory, scope : String, key : String) -> Entry? {
  ignore(self.expire_due())
  self.lookup(scope, key)
}

///|
/// The live keys of a scope, in order.
fn Memory::keys_in(self : Memory, scope : String) -> Array[String] {
  ignore(self.expire_due())
  let out : Array[String] = []
  match self.entries.get(scope) {
    Some(inner) =>
      for k in inner.keys() {
        out.push(k)
      }
    None => ()
  }
  sort_strings(out)
  out
}

///|
/// The live entries of a scope, in key order.
fn Memory::entries_in(self : Memory, scope : String) -> Array[Entry] {
  ignore(self.expire_due())
  let out : Array[Entry] = []
  match self.entries.get(scope) {
    Some(inner) =>
      for (_, entry) in inner.iter() {
        out.push(entry)
      }
    None => ()
  }
  out.sort_by(fn(a, b) { @tesseract.compare_text(a.key, b.key) })
  out
}

///|
/// Forget everything in one scope.
fn Memory::clear_in(self : Memory, scope : String) -> Unit {
  ignore(self.expire_due())
  match self.entries.get(scope) {
    None => ()
    Some(inner) => {
      for (_, entry) in inner.iter() {
        self.bytes = self.bytes - entry_bytes(entry)
      }
      ignore(self.entries.remove_and_get(scope))
    }
  }
}

///|
/// Remove every entry whose time is up, and say how many went.
///
/// The clock is read directly rather than through `now`, which removes what
/// has expired — a call that swept the store from inside the sweep would
/// never end.
fn Memory::expire_due(self : Memory) -> Int64 {
  let now = self.clock.read()
  let dead : Array[(String, String)] = []
  for (scope, inner) in self.entries.iter() {
    for (key, entry) in inner.iter() {
      if entry.expired(now) {
        dead.push((scope, key))
      }
    }
  }
  let mut gone = 0L
  for d in dead {
    if self.forget(d.0, d.1) {
      gone = gone + 1L
    }
  }
  self.stats.expirations = self.stats.expirations + gone
  gone
}

///|
/// The entry the policy would evict, or `None` when there is nothing to evict.
///
/// The tie-break is the scope and then the key, so the same sequence of
/// operations always evicts the same entry. A store that evicts differently on
/// two runs of the same program is a store nobody can test.
///
/// The excluded pair is the key being written. It is never the victim: an
/// entry is not evicted to make room for the value that is about to replace
/// it. An entry that is not there cannot be a victim anyway, so the exclusion
/// is the same whether the key is new or not.
///
/// A **pinned** entry is not a victim either, and that is not a preference
/// the policy may overrule — it is the whole meaning of the pin. A store
/// whose every entry is pinned has no victim at all, and the write that
/// needed the room is refused.
fn Memory::pick_victim(
  self : Memory,
  exclude_scope : String,
  exclude_key : String,
) -> (String, String)? {
  let mut best : (String, String)? = None
  let mut best_rank = 0L
  for (scope, inner) in self.entries.iter() {
    for (key, entry) in inner.iter() {
      if scope == exclude_scope && key == exclude_key {
        continue
      }
      if entry.pinned {
        continue
      }
      let rank = match self.config.eviction {
        LeastRecentlyUsed => entry.last_seen
        LeastFrequentlyUsed => entry.hits
        SoonestExpiry =>
          if entry.window_ms == 0L {
            NEVER_EXPIRES
          } else {
            entry.deadline
          }
        OldestFirst => entry.added_at
      }
      match best {
        None => {
          best = Some((scope, key))
          best_rank = rank
        }
        Some(current) =>
          if rank < best_rank ||
            (
              rank == best_rank &&
              scope_key_compare(scope, key, current.0, current.1) < 0
            ) {
            best = Some((scope, key))
            best_rank = rank
          }
      }
    }
  }
  best
}

///|
/// Sort strings by their letters.
fn sort_strings(items : Array[String]) -> Unit {
  items.sort_by(fn(a, b) { @tesseract.compare_text(a, b) })
}

///|
/// Compare a scope and a key against another scope and a key.
///
/// The scope comes first, so the eviction order does not depend on the order
/// the scopes or the entries happened to be written in: two entries that tie
/// on the policy are separated by where they live, and then by their key.
///
/// The order is by **letters** — `compare_text`, not the runtime's
/// `String::compare`, which compares the lengths first and would make the
/// scope called "work" come before the scope called "default".
fn scope_key_compare(
  scope : String,
  key : String,
  other_scope : String,
  other_key : String,
) -> Int32 {
  let by_scope = @tesseract.compare_text(scope, other_scope)
  if by_scope != 0 {
    by_scope
  } else {
    @tesseract.compare_text(key, other_key)
  }
}
