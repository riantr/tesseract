///|
/// A named partition of a memory's keyspace.
///
/// A scope is **not** a second store. It is a partition of one store: it
/// shares the memory's clock, its budget, its statistics and its eviction,
/// and the only thing it has of its own is the set of keys it holds. Two
/// scopes can hold the same key without either of them seeing the other's
/// entry, and a write into one of them can evict an entry from the other —
/// because the capacity and the byte budget are the store's, and a partition
/// of a pool does not get a pool of its own.
///
/// The scope is a **handle**, not a copy: it reads and writes the same
/// entries the memory holds, so a scope taken before a write sees the write,
/// and the byte total cannot drift between the two of them.
///
/// ```moonbit nocheck
/// let m = @tesseract_memory.new_memory(100)
/// let work = m.scope("work")
/// ignore(work.put("todo", "ship 0.1.7"))
/// ignore(m.scope("notes").put("todo", "buy milk"))
/// // The two are the same key in different scopes.
/// assert_eq(work.get("todo"), Some("ship 0.1.7"))
/// assert_eq(m.scope("notes").get("todo"), Some("buy milk"))
/// ```
pub struct Scope {
  priv memory : Memory
  priv name : String
}

///|
/// The scope called `name`.
///
/// The scope does not have to exist yet: a scope is created by the first write
/// into it, and a scope that holds nothing is not one the store reports.
///
/// The handle is a window onto the memory, not a copy of it, so the two see
/// the same entries, the same clock and the same byte total.
pub fn Memory::scope(self : Memory, name : String) -> Scope {
  { memory: self, name, }
}

///|
/// The default scope — the one the memory's own methods address.
pub fn Memory::default_scope(self : Memory) -> Scope {
  self.scope(default_scope_name())
}

///|
/// The names of the scopes that hold something, in order.
///
/// A scope with no live entries is not listed: it is not a scope yet, and
/// listing it would send the caller looking in a place where there is nothing
/// to find.
pub fn Memory::scopes(self : Memory) -> Array[String] {
  ignore(self.expire_due())
  let out : Array[String] = []
  for (name, inner) in self.entries.iter() {
    if inner.length() > 0 {
      out.push(name)
    }
  }
  out.sort_by(fn(a, b) { @tesseract.compare_text(a, b) })
  out
}

///|
/// The name of the scope.
pub fn Scope::name(self : Scope) -> String {
  self.name
}

///|
/// The store's default TTL — the lifetime a `put` gets when it does not ask
/// for one of its own.
///
/// It is the **store's** default and not the scope's: the scopes of one
/// memory share their configuration, so there is nothing to configure twice.
pub fn Scope::default_ttl(self : Scope) -> Ttl {
  self.memory.config.default_ttl
}

///|
/// Write a value under a key, with the default TTL.
///
/// The TTL is the **store's** default, so every scope of one memory expires
/// on the same policy.
pub fn Scope::put(self : Scope, key : String, value : String) -> Bool {
  self.memory.put_in(self.name, key, value, self.memory.config.default_ttl)
}

///|
/// Write a value under a key, with a TTL of this entry's own.
///
/// The room it makes is made out of the store: the eviction that follows can
/// take an entry from another scope, because the budget is the store's.
pub fn Scope::put_with_ttl(
  self : Scope,
  key : String,
  value : String,
  ttl : Ttl,
) -> Bool {
  self.memory.put_in(self.name, key, value, ttl)
}

///|
/// Read a value, and count it as a use.
///
/// A hit touches the entry: the idle clock restarts, the hit count goes up,
/// and a sliding entry's deadline moves forward.
pub fn Scope::get(self : Scope, key : String) -> String? {
  self.memory.get_in(self.name, key)
}

///|
/// Whether a key is live in this scope.
///
/// The answer is about **this** scope: the same key in another scope is a
/// different entry, and is not here.
pub fn Scope::contains(self : Scope, key : String) -> Bool {
  self.memory.contains_in(self.name, key)
}

///|
/// Refresh an entry without reading it.
///
/// This is what a sliding TTL is for, and it is also how a caller says "this is
/// still relevant" about something it did not read. Returns false when the key
/// is not there.
pub fn Scope::touch(self : Scope, key : String) -> Bool {
  self.memory.touch_in(self.name, key)
}

///|
/// Forget a key.
///
/// Returns false when there was nothing to forget.
pub fn Scope::delete(self : Scope, key : String) -> Bool {
  self.memory.delete_in(self.name, key)
}

///|
/// One entry, by key, from this scope.
pub fn Scope::entry(self : Scope, key : String) -> Entry? {
  self.memory.entry_in(self.name, key)
}

///|
/// The live keys of this scope, in order.
pub fn Scope::keys(self : Scope) -> Array[String] {
  self.memory.keys_in(self.name)
}

///|
/// The live entries of this scope, in key order.
pub fn Scope::entries(self : Scope) -> Array[Entry] {
  self.memory.entries_in(self.name)
}

///|
/// How many entries are live in this scope.
///
/// This is the scope's share of the store's count: `Memory::size` is the
/// whole store's, and the capacity is spent against that one.
pub fn Scope::size(self : Scope) -> Int32 {
  self.memory.keys_in(self.name).length()
}

///|
/// How many bytes this scope's values take up.
///
/// UTF-8 bytes, the same unit the store's budget is stated in. The store's own
/// total is `Memory::size_bytes`; this is the part of it that belongs to this
/// scope.
pub fn Scope::size_bytes(self : Scope) -> Int64 {
  ignore(self.memory.expire_due())
  let mut bytes = 0L
  for entry in self.memory.entries_in(self.name) {
    bytes = bytes + utf8_bytes(entry.value)
  }
  bytes
}

///|
/// Forget everything in this scope.
///
/// The other scopes are left alone, and so are the statistics: a memory that
/// has served two thousand requests and was then cleared has still served two
/// thousand requests.
pub fn Scope::clear(self : Scope) -> Unit {
  self.memory.clear_in(self.name)
}

///|
/// The entries of this scope most like `query`, best first.
///
/// The same search as the store's, over this scope's entries only: an entry
/// in another scope is not a candidate, however well it matches.
pub fn Scope::search(self : Scope, query : String, k : Int32) -> Array[Hit] {
  self.memory.search_in(self.name, query, k)
}

///|
/// The keys of this scope's entries most like `query`, best first.
pub fn Scope::search_keys(
  self : Scope,
  query : String,
  k : Int32,
) -> Array[String] {
  self.memory.search_keys_in(self.name, query, k)
}
