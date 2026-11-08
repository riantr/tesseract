///|
/// A short-term memory that survives the process.
///
/// The memory tier is a store in memory: every entry it holds is gone when
/// the process ends. This is the same tier with a **checkpoint** — a `.db`
/// file the store is written to and read back from — so a memory can be
/// closed and reopened without losing what it was holding.
///
/// The checkpoint is a **lattice of its own**. It is not the sudoku store and
/// it never shares a cell with one: the sudoku records and the memory's
/// entries are different things with different rules, and a write that landed
/// on the wrong one would be a bug in a layer neither of them knows about.
/// So the checkpoint has its own lattice, and the file it writes is a
/// **checkpoint container** — a lattice whose cells hold the memory's
/// entries — rather than a tesseract database a person would query.
///
/// Two rules hold, and both are the point of the thing:
///
/// - **A reload brings back exactly the entries that were live.** An entry
///   whose time was up when the checkpoint was written is not in the file, and
///   an entry whose time is up by the time the file is read is dropped again.
///   What comes back is the live set, not the written set.
///
/// - **A refused write leaves the store unchanged.** A write the store cannot
///   honour — a spec it cannot use, or one that does not fit — is refused
///   before anything is touched, and a refused write writes no checkpoint
///   either. The store and the file are the same store.
///
/// The **absolute** deadline is what makes the first rule true. A checkpoint
/// that stored the lifetime an entry was given would move every deadline
/// forward by however long the store was closed, so a store reopened after an
/// hour would hold entries an hour younger than they were. The deadline is
/// the fact; the lifetime is only a way of arriving at it.
///
/// The clock goes into the checkpoint too, and comes back with it: a store on
/// a manual clock that was reopened on a fresh one would find its entries
/// *younger* than they were, and an age of minus an hour is not a thing a
/// store should report.
pub struct DurableMemory {
  priv memory : @tesseract_memory.Memory
  priv path : String
}

///|
/// A scope of a durable memory.
///
/// A scope is a partition of the store, and a write into one is a write to the
/// store — so it is checkpointed the same way. The scope on its own would not
/// be: this is the one that keeps the file and the store the same store.
pub struct DurableScope {
  priv scope : @tesseract_memory.Scope
  priv memory : @tesseract_memory.Memory
  priv path : String
}

///|
/// The smallest side a checkpoint lattice is ever built at.
///
/// The lattice holds the header in its first cell and one entry in each cell
/// after it, so a side-4 lattice holds 255 entries — more than the memory's own
/// default of a hundred. It stays the **floor** rather than being derived from
/// the capacity for a reason worth keeping: every checkpoint written before the
/// side was recorded is a side-4 file, so a store that still fits in 255 keeps
/// writing exactly the shape of file it always did. The file a small store
/// writes does not change.
const CHECKPOINT_MIN_SIDE : Int64 = 4L

///|
/// The largest side this build will build a checkpoint lattice at — and the
/// largest it will read.
///
/// A side-10 lattice holds 9999 entries, which is 39 times the 255 a side-4
/// lattice holds. It is not larger because the store is one **flat array of
/// `side^4` cells**: a side-10 checkpoint allocates ten thousand cells and
/// walks them on every write, so the ceiling is a memory cost, not a disk one.
/// A store that grows past this wants storage that is not one flat array, which
/// is a different design rather than a larger number here.
///
/// The side a checkpoint was written with is recorded in the file, so a
/// checkpoint is readable by any build whose maximum is at least its side. That
/// is the guarantee, and it is the honest one: it replaces "one fixed size for
/// everybody", which could not be both 255 and enough.
const CHECKPOINT_MAX_SIDE : Int64 = 10L

///|
/// The most entries a checkpoint holds: `side^4 - 1` at the largest side,
/// because the header takes one cell.
///
/// Public so a caller can ask instead of hard-coding a number that has moved.
pub fn max_entries() -> Int32 {
  checkpoint_capacity(CHECKPOINT_MAX_SIDE)
}

///|
/// How many entries a side-`side` checkpoint lattice holds.
fn checkpoint_capacity(side : Int64) -> Int32 {
  (side * side * side * side - 1L).to_int()
}

///|
/// The smallest side that holds `entries` entries plus the header.
///
/// Smallest rather than always the largest, because the lattice is a flat
/// array: a store holding 300 entries on a side-10 lattice would allocate
/// 10,000 cells to write 301 of them.
fn checkpoint_side_for(entries : Int32) -> Result[Int64, String] {
  let mut side = CHECKPOINT_MIN_SIDE
  while side <= CHECKPOINT_MAX_SIDE {
    if checkpoint_capacity(side) >= entries {
      return Ok(side)
    }
    side = side + 1L
  }
  Err(
    "a checkpoint holds at most " +
    max_entries().to_string() +
    " entries, and this one would need " +
    entries.to_string(),
  )
}

///|
/// Opens the memory in the file at `path`, reading the checkpoint if there is
/// one.
///
/// A path that does not exist yet is not an error: the file is created empty
/// and the memory starts empty. A path whose **directory** does not exist is
/// an error, because that is a path that cannot be written.
///
/// The clock in the checkpoint wins over the clock this would otherwise use.
/// A store on a manual clock that was reopened on a fresh one would find its
/// entries younger than they were, and the age it reports would be negative.
pub fn open(
  path : String,
  config : @tesseract_memory.Config,
) -> Result[DurableMemory, String] {
  open_with_clock(path, config, @tesseract_memory.memory_clock_system())
}

///|
/// Opens the memory in the file at `path`, reading the checkpoint if there is
/// one, and using `clock` when the file does not carry one.
///
/// The clock is only a starting point: a checkpoint that carries a **manual**
/// clock brings that one back instead, because the entries in it were written
/// on that timeline and reading them on another would move them. A checkpoint
/// that carries the **system** clock says nothing about the timeline — the
/// host's clock is the host's clock — so the clock this was opened with is
/// the one in force.
pub fn open_with_clock(
  path : String,
  config : @tesseract_memory.Config,
  clock : @tesseract_memory.MemoryClock,
) -> Result[DurableMemory, String] {
  if config.capacity > max_entries() {
    return Err(
      "a durable memory holds at most " +
      max_entries().to_string() +
      " entries, because the checkpoint lattice holds one cell per entry and one for the header",
    )
  }
  let lattice = match read_checkpoint_lattice(path) {
    Ok(l) => l
    Err(message) => return Err(message)
  }
  let loaded = match load_file(path, lattice) {
    Ok(n) => n
    Err(message) => return Err(message)
  }
  // A file that holds no cells at all is a new store, and a new store has no
  // header yet. A file that holds cells must have a header this build
  // understands as its first one, or it is not a checkpoint this build may
  // read - and saying so is better than coming back with a store that
  // quietly lost the entries the header was there to protect.
  let stored_clock = if loaded == 0 {
    clock
  } else {
    match read_header_cell(lattice, path) {
      Ok(c) => if c.is_manual() { c } else { clock }
      Err(message) => return Err(message)
    }
  }
  let memory = @tesseract_memory.new_memory_with_clock(config, stored_clock)
  let entries = read_entry_cells(lattice)
  // The limits are checked **before** anything is restored, because restoring
  // an entry into a store that is already full would evict the entries that
  // were there. A file that does not fit the store it is opened with is
  // refused rather than half-loaded.
  if entries.length() > config.capacity {
    return Err(
      "the checkpoint holds " +
      entries.length().to_string() +
      " entries and the capacity is " +
      config.capacity.to_string(),
    )
  }
  let bytes = total_bytes(entries)
  if config.max_bytes > 0L && bytes > config.max_bytes {
    return Err(
      "the checkpoint holds " +
      bytes.to_string() +
      " bytes and the budget is " +
      config.max_bytes.to_string(),
    )
  }
  for entry in entries {
    ignore(memory.restore_entry(entry))
  }
  Ok({ memory, path, })
}

///|
/// The file the memory is checkpointed to.
pub fn DurableMemory::path(self : DurableMemory) -> String {
  self.path
}

///|
/// The store itself.
///
/// The writes on it are **not** checkpointed — a write through this handle
/// changes the memory and leaves the file behind. Use the memory's own
/// methods, or its scopes', which checkpoint what they write.
pub fn DurableMemory::memory(self : DurableMemory) -> @tesseract_memory.Memory {
  self.memory
}

///|
/// Writes the checkpoint, and says how many entries it holds.
///
/// The store is swept first, so what is written is what is **live**: an entry
/// whose time is up is not in the file, and it will not come back.
pub fn DurableMemory::checkpoint(self : DurableMemory) -> Result[Int32, String] {
  write_checkpoint(self.memory, self.path)
}

///|
/// Reads the checkpoint back into the store, replacing what it holds.
///
/// The entries the file carries are the ones that come back, and the ones it
/// does not carry are gone.
///
/// The **clock is the store's**: a reload does not move it. The entries carry
/// absolute deadlines, so what is live is decided by the clock the store is
/// on — an entry that clock puts in the past does not come back. The store
/// itself is not replaced either: the handle it handed out stays the handle,
/// and a reload that swapped the store out from under it would leave the
/// caller holding a store that is no longer the one it opened.
pub fn DurableMemory::reload(self : DurableMemory) -> Result[Int32, String] {
  let lattice = match read_checkpoint_lattice(self.path) {
    Ok(l) => l
    Err(message) => return Err(message)
  }
  let loaded = match load_file(self.path, lattice) {
    Ok(n) => n
    Err(message) => return Err(message)
  }
  // The header is checked **before** the store is cleared. A reload that
  // emptied the store and then failed would leave the caller with nothing
  // and an error, and those two together are worse than either of them: the
  // entries are gone whether or not the reload worked. A file this build
  // cannot read leaves the store holding exactly what it held.
  if loaded > 0 {
    match read_header_cell(lattice, self.path) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  let entries = read_entry_cells(lattice)
  @tesseract_memory.Memory::clear(self.memory)
  for entry in entries {
    ignore(self.memory.restore_entry(entry))
  }
  Ok(entries.length())
}

///|
/// Writes a value under a key, and checkpoints the store.
///
/// `Ok(false)` is a **refused** write: the store would not take it, and
/// nothing was touched — not the store and not the file. `Err` is a write
/// that was taken but could not be checkpointed, which leaves the file
/// behind the store; the next checkpoint catches up.
pub fn DurableMemory::put(
  self : DurableMemory,
  key : String,
  value : String,
) -> Result[Bool, String] {
  let ok = self.memory.put(key, value)
  if ok {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Writes a value under a key with a lifetime, and checkpoints the store.
pub fn DurableMemory::put_with_ttl(
  self : DurableMemory,
  key : String,
  value : String,
  ttl : @tesseract_memory.Ttl,
) -> Result[Bool, String] {
  let ok = self.memory.put_with_ttl(key, value, ttl)
  if ok {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Writes a value under a key with a spec, and checkpoints the store.
pub fn DurableMemory::put_spec(
  self : DurableMemory,
  key : String,
  value : String,
  spec : @tesseract_memory.EntrySpec,
) -> Result[Bool, String] {
  let ok = self.memory.put_spec(key, value, spec)
  if ok {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Forgets a key, and checkpoints the store.
pub fn DurableMemory::delete(
  self : DurableMemory,
  key : String,
) -> Result[Bool, String] {
  let gone = self.memory.delete(key)
  if gone {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Refreshes a key without reading it, and checkpoints the store.
pub fn DurableMemory::touch(
  self : DurableMemory,
  key : String,
) -> Result[Bool, String] {
  let touched = self.memory.touch(key)
  if touched {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Pins an entry so it is never evicted to make room, and checkpoints.
pub fn DurableMemory::pin(
  self : DurableMemory,
  key : String,
) -> Result[Bool, String] {
  let pinned = self.memory.pin(key)
  if pinned {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Unpins an entry so it can be evicted again, and checkpoints.
pub fn DurableMemory::unpin(
  self : DurableMemory,
  key : String,
) -> Result[Bool, String] {
  let unpinned = self.memory.unpin(key)
  if unpinned {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Forgets everything in every scope, and checkpoints.
pub fn DurableMemory::clear(self : DurableMemory) -> Result[Unit, String] {
  @tesseract_memory.Memory::clear(self.memory)
  match self.checkpoint() {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
/// Moves a manual clock forward, and checkpoints.
///
/// The checkpoint carries the clock, so a store that is reopened comes back
/// on the timeline it was left on.
pub fn DurableMemory::advance(
  self : DurableMemory,
  ms : Int64,
) -> Result[Bool, String] {
  let moved = self.memory.advance(ms)
  if moved {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Drops what has expired, and checkpoints.
pub fn DurableMemory::sweep(self : DurableMemory) -> Result[Int64, String] {
  let gone = self.memory.sweep()
  match self.checkpoint() {
    Ok(_) => Ok(gone)
    Err(message) => Err(message)
  }
}

///|
/// Changes the store's settings, and checkpoints.
///
/// A capacity above what a checkpoint lattice can hold is refused, because a
/// store that could not be written out is not a store that can be reopened.
pub fn DurableMemory::set_config(
  self : DurableMemory,
  config : @tesseract_memory.Config,
) -> Result[Bool, String] {
  if config.capacity > max_entries() {
    return Err(
      "a durable memory holds at most " +
      max_entries().to_string() +
      " entries, because the checkpoint lattice holds one cell per entry and one for the header",
    )
  }
  let ok = self.memory.set_config(config)
  if ok {
    match self.checkpoint() {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Reads a value. A hit touches the entry, and the touch is not checkpointed
/// until the next write: the file holds the entries, and a hit count that is
/// a write behind does not change which entries are live.
pub fn DurableMemory::get(self : DurableMemory, key : String) -> String? {
  self.memory.get(key)
}

///|
/// Whether a key is live.
pub fn DurableMemory::contains(self : DurableMemory, key : String) -> Bool {
  self.memory.contains(key)
}

///|
/// The live keys of the default scope.
pub fn DurableMemory::keys(self : DurableMemory) -> Array[String] {
  self.memory.keys()
}

///|
/// The live entries of the default scope.
pub fn DurableMemory::entries(
  self : DurableMemory,
) -> Array[@tesseract_memory.Entry] {
  self.memory.entries()
}

///|
/// One entry, by key, from the default scope.
pub fn DurableMemory::entry(
  self : DurableMemory,
  key : String,
) -> @tesseract_memory.Entry? {
  self.memory.entry(key)
}

///|
/// The number of live entries.
pub fn DurableMemory::size(self : DurableMemory) -> Int32 {
  self.memory.size()
}

///|
/// How many bytes the stored content takes up.
pub fn DurableMemory::size_bytes(self : DurableMemory) -> Int64 {
  self.memory.size_bytes()
}

///|
/// What the store has done.
pub fn DurableMemory::stats(self : DurableMemory) -> @tesseract_memory.Stats {
  self.memory.stats()
}

///|
/// The scopes that hold something.
pub fn DurableMemory::scopes(self : DurableMemory) -> Array[String] {
  self.memory.scopes()
}

///|
/// The entries most like the query.
pub fn DurableMemory::search(
  self : DurableMemory,
  query : String,
  k : Int32,
) -> Array[@tesseract_memory.Hit] {
  self.memory.search(query, k)
}

///|
/// The entries most like the query, and the ones the filter keeps.
pub fn DurableMemory::search_filtered(
  self : DurableMemory,
  query : String,
  k : Int32,
  filter : @tesseract_memory.MetadataFilter,
) -> Array[@tesseract_memory.Hit] {
  self.memory.search_filtered(query, k, filter)
}

///|
/// A named partition of the store.
///
/// The scope writes and checkpoints the same way the store's own writes do,
/// because a scope is a partition of the store and not a store of its own.
pub fn DurableMemory::scope(
  self : DurableMemory,
  name : String,
) -> DurableScope {
  { scope: self.memory.scope(name), memory: self.memory, path: self.path, }
}

///|
/// The default scope.
pub fn DurableMemory::default_scope(self : DurableMemory) -> DurableScope {
  { scope: self.memory.default_scope(), memory: self.memory, path: self.path, }
}

///|
/// The name of the scope.
pub fn DurableScope::name(self : DurableScope) -> String {
  self.scope.name()
}

///|
/// Writes a value under a key, and checkpoints the store.
pub fn DurableScope::put(
  self : DurableScope,
  key : String,
  value : String,
) -> Result[Bool, String] {
  let ok = self.scope.put(key, value)
  if ok {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Writes a value under a key with a lifetime, and checkpoints the store.
pub fn DurableScope::put_with_ttl(
  self : DurableScope,
  key : String,
  value : String,
  ttl : @tesseract_memory.Ttl,
) -> Result[Bool, String] {
  let ok = self.scope.put_with_ttl(key, value, ttl)
  if ok {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Writes a value under a key with a spec, and checkpoints the store.
pub fn DurableScope::put_spec(
  self : DurableScope,
  key : String,
  value : String,
  spec : @tesseract_memory.EntrySpec,
) -> Result[Bool, String] {
  let ok = self.scope.put_spec(key, value, spec)
  if ok {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Forgets a key, and checkpoints the store.
pub fn DurableScope::delete(
  self : DurableScope,
  key : String,
) -> Result[Bool, String] {
  let gone = self.scope.delete(key)
  if gone {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Refreshes a key without reading it, and checkpoints the store.
pub fn DurableScope::touch(
  self : DurableScope,
  key : String,
) -> Result[Bool, String] {
  let touched = self.scope.touch(key)
  if touched {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Pins an entry so it is never evicted to make room, and checkpoints.
pub fn DurableScope::pin(
  self : DurableScope,
  key : String,
) -> Result[Bool, String] {
  let pinned = self.scope.pin(key)
  if pinned {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Unpins an entry so it can be evicted again, and checkpoints.
pub fn DurableScope::unpin(
  self : DurableScope,
  key : String,
) -> Result[Bool, String] {
  let unpinned = self.scope.unpin(key)
  if unpinned {
    match write_checkpoint(self.memory, self.path) {
      Ok(_) => Ok(true)
      Err(message) => Err(message)
    }
  } else {
    Ok(false)
  }
}

///|
/// Forgets everything in this scope, and checkpoints the store.
pub fn DurableScope::clear(self : DurableScope) -> Result[Unit, String] {
  self.scope.clear()
  match write_checkpoint(self.memory, self.path) {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
/// Reads a value.
pub fn DurableScope::get(self : DurableScope, key : String) -> String? {
  self.scope.get(key)
}

///|
/// Whether a key is live.
pub fn DurableScope::contains(self : DurableScope, key : String) -> Bool {
  self.scope.contains(key)
}

///|
/// The live keys of this scope.
pub fn DurableScope::keys(self : DurableScope) -> Array[String] {
  self.scope.keys()
}

///|
/// The live entries of this scope.
pub fn DurableScope::entries(
  self : DurableScope,
) -> Array[@tesseract_memory.Entry] {
  self.scope.entries()
}

///|
/// One entry, by key, from this scope.
pub fn DurableScope::entry(
  self : DurableScope,
  key : String,
) -> @tesseract_memory.Entry? {
  self.scope.entry(key)
}

///|
/// The number of live entries in this scope.
pub fn DurableScope::size(self : DurableScope) -> Int32 {
  self.scope.size()
}

///|
/// The entries most like the query.
pub fn DurableScope::search(
  self : DurableScope,
  query : String,
  k : Int32,
) -> Array[@tesseract_memory.Hit] {
  self.scope.search(query, k)
}

///|
/// Writes the checkpoint: the store, swept, into a lattice of its own.
///
/// The sweep comes first, so what is written is what is **live**. An entry
/// whose time is up is not in the file, and it does not come back.
///
/// The entries are encoded **before** the lattice is built, because the lattice
/// is sized from how many there are: the smallest side that holds them, so a
/// store of a hundred entries pays for 256 cells rather than for the ten
/// thousand the largest checkpoint could hold. That side is what the file
/// records, and it is what a reader sizes its own lattice from.
fn write_checkpoint(
  memory : @tesseract_memory.Memory,
  path : String,
) -> Result[Int32, String] {
  let encoded : Array[(String, String)] = []
  for scope in memory.scopes() {
    for entry in memory.scope(scope).entries() {
      encoded.push((cell_key(entry.key()), encode_entry(entry)))
    }
  }
  let side = match checkpoint_side_for(encoded.length()) {
    Ok(s) => s
    Err(message) => return Err(message)
  }
  let lattice = match new_checkpoint_lattice(side) {
    Ok(l) => l
    Err(message) => return Err(message)
  }
  if !insert_cell(lattice, 1L, HEADER_KEY, encode_header(memory.clock())) {
    return Err("the checkpoint header could not be written at " + path)
  }
  let mut position = 2L
  for cell in encoded {
    if !insert_cell(lattice, position, cell.0, cell.1) {
      return Err(
        "the entry at position " +
        position.to_string() +
        " of " +
        encoded.length().to_string() +
        " could not be written at " +
        path,
      )
    }
    position = position + 1L
  }
  save_file(path, lattice)
}

///|
/// A fresh lattice for a checkpoint, of the given side.
///
/// It is a lattice of its own: the sudoku records and the memory's entries
/// never share a cell, because they are different things with different rules
/// and a write that landed on the wrong one would be a bug in a layer neither
/// of them knows about.
///
/// A side this build cannot build is an error rather than a fallback. There
/// used to be a fallback here — to the 3-per-axis lattice — and it was the one
/// failure mode that would have been silent: a side-3 checkpointer holds 79
/// entries, so a store that overflowed it would have written a file that was
/// missing entries while reporting success.
fn new_checkpoint_lattice(side : Int64) -> Result[@tesseract.Tesseract, String] {
  let lat = match @tesseract.lattice_of(side) {
    Ok(l) => l
    Err(message) => return Err(message)
  }
  let logger = @tesseract.new_logger("tesseract-memory-db")
  Ok(@tesseract.new_db("tesseract-memory", lat, logger))
}

///|
/// A lattice sized for the checkpoint at `path`.
///
/// The reader cannot build a lattice until it knows the side, and the side is
/// in the file rather than in the build: that is what lets one build read a
/// checkpoint written by a store with a larger capacity. A file that carries no
/// side was written by a store from before the side was recorded, and every one
/// of those is a side-4 lattice.
///
/// A file written on a lattice **larger** than this build can address is
/// refused, by name. The alternative is not "read what fits": the rows above
/// this lattice's last position are refused one by one by `insert_stamped`, and
/// a reader that ignored that count would hand back a store quietly missing its
/// tail.
fn read_checkpoint_lattice(
  path : String,
) -> Result[@tesseract.Tesseract, String] {
  let recorded = @tesseract_sqlite.saved_side(path) catch {
    _ => return Err("the checkpoint at " + path + " could not be opened")
  }
  let side = match recorded {
    Some(s) =>
      if s < CHECKPOINT_MIN_SIDE {
        // A side below the floor is not one this build writes, but it is one it
        // can read: a smaller lattice's positions are a prefix of a larger one's.
        CHECKPOINT_MIN_SIDE
      } else {
        s
      }
    None => CHECKPOINT_MIN_SIDE
  }
  if side > CHECKPOINT_MAX_SIDE {
    return Err(
      "the file at " +
      path +
      " is a checkpoint written on a lattice of side " +
      side.to_string() +
      ", and this build reads at most side " +
      CHECKPOINT_MAX_SIDE.to_string(),
    )
  }
  new_checkpoint_lattice(side)
}

///|
/// Writes one cell of the checkpoint, and says whether it landed.
///
/// The cell carries no digit, so the sudoku rule has nothing to say about it:
/// a checkpoint is a container, not a puzzle.
///
/// The answer is the caller's to check rather than to ignore. A cell that does
/// not land — the one way a lattice can refuse a write is to be too small — used
/// to be dropped here, so a checkpoint could be written missing its tail and
/// still be reported as written. The count the lattice was sized from comes from
/// the same list that is being written, so this cannot fire; it is checked
/// because "cannot fire" is what the two silent losses this release fixed both
/// looked like from the inside.
fn insert_cell(
  lattice : @tesseract.Tesseract,
  position : Int64,
  key : String,
  value : String,
) -> Bool {
  @tesseract.Tesseract::insert_stamped(
    lattice,
    key,
    value,
    Some(position),
    @tesseract.NO_DIGIT,
    None,
  ).success
}

///|
/// The name a cell carries for an entry.
///
/// It is the entry's own key, because that is what a person reading the file
/// wants to see. An entry with no key is a thing the store should not hold,
/// but one that is there gets a name that is not empty, because a cell with
/// no name cannot be written.
fn cell_key(key : String) -> String {
  if key == "" {
    "?"
  } else {
    key
  }
}

///|
/// The clock the checkpoint carries, or the reason the file is not one.
///
/// The header is a **guard**, not a hint. A file that holds cells but whose
/// first cell is not a header this build understands is refused, so that the
/// promise `FORMAT_VERSION` makes - refused rather than half-read - is kept
/// where it matters. The two refusals are kept apart because they are
/// different mistakes: a file that is not a checkpoint at all, and a
/// checkpoint this build does not know how to read.
fn read_header_cell(
  lattice : @tesseract.Tesseract,
  path : String,
) -> Result[@tesseract_memory.MemoryClock, String] {
  match @tesseract.Tesseract::cell_at(lattice, 1L) {
    Some(cell) =>
      if cell.key != HEADER_KEY {
        Err(
          "the file at " +
          path +
          " is not a tesseract-memory checkpoint: its first cell is named '" +
          cell.key +
          "'",
        )
      } else {
        decode_header(cell.value)
      }
    None =>
      Err(
        "the file at " + path + " has no header cell, so it is not a checkpoint",
      )
  }
}

///|
/// The entries the checkpoint carries, in the order the cells hold them.
fn read_entry_cells(
  lattice : @tesseract.Tesseract,
) -> Array[@tesseract_memory.Entry] {
  let out : Array[@tesseract_memory.Entry] = []
  let lat = @tesseract.Tesseract::lattice_of_db(lattice)
  let mut position = 2L
  while position <= lat.last_position() {
    match @tesseract.Tesseract::cell_at(lattice, position) {
      Some(cell) =>
        match decode_entry(cell.value) {
          Some(entry) => out.push(entry)
          None => ()
        }
      None => ()
    }
    position = position + 1L
  }
  out
}

///|
/// How many bytes a set of entries takes up: their values and their labels.
fn total_bytes(entries : Array[@tesseract_memory.Entry]) -> Int64 {
  let mut total = 0L
  for entry in entries {
    total = total +
      @tesseract_memory.utf8_bytes(entry.value()) +
      entry.metadata().bytes()
  }
  total
}

///|
/// Reads the file into the lattice.
///
/// A load that **rejected** rows is a failure, not a partial success. The
/// lattice the reader built is sized from the side the file records, so a
/// rejection means the file and its own record of itself disagree — a
/// hand-edited file, or one written by something that got the side wrong. Both
/// are cases where "loaded 200 of 219" and "loaded 200" are different answers,
/// and only the first one is what happened.
fn load_file(
  path : String,
  lattice : @tesseract.Tesseract,
) -> Result[Int32, String] {
  let report = @tesseract_sqlite.load(path, lattice) catch {
    _ => return Err("the checkpoint at " + path + " could not be read")
  }
  if report.rejected > 0 {
    return Err(
      "the checkpoint at " +
      path +
      " holds " +
      report.rejected.to_string() +
      " cells its lattice cannot address, so it was not read",
    )
  }
  Ok(report.loaded)
}

///|
/// Writes the lattice to the file.
fn save_file(
  path : String,
  lattice : @tesseract.Tesseract,
) -> Result[Int32, String] {
  let rows = @tesseract_sqlite.save(path, lattice) catch {
    _ => return Err("the checkpoint at " + path + " could not be written")
  }
  Ok(rows)
}
