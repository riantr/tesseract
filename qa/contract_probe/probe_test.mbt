///|
/// The questions the checkpoint format's contract has to answer.
///
/// Every line this probe prints starts with `PROBE ` and is
/// `PROBE <name> <value>`, so the harness can read the facts out of the test
/// output without parsing anything clever.
///
/// A test that fails here is not a broken probe: it is the probe reporting
/// that the format does not do what its own documentation says it does.

///|
/// The published package's opaque value types, read through their accessors.
///
/// 0.1.14 made `Lattice`, `Entry` and `Hit` opaque: their fields are private
/// and every field has an accessor. The registry's index *advertises* those
/// accessors, and the contract audit compares that index with the tree — which
/// proves the index is not lying about a name, and nothing about whether a
/// consumer can call it or what it returns.
///
/// This test does both. It is compiled against the **published** package, so
/// an accessor that is missing or renamed is a compile error, and it asserts
/// the numbers, so an accessor that returns the wrong thing fails the run.
test "the published package's accessors return the numbers the contract names" {
  // The lattice. A side of 4 is 256 cells, addressed 1..256, with digits
  // 1..4.
  let shape = match @tesseract_qa_contract_probe.lattice_shape(4L) {
    Ok(s) => s
    Err(message) => {
      println("PROBE lattice_error " + message)
      fail("the published package could not build a lattice of side 4")
    }
  }
  println("PROBE lattice_side " + shape.side.to_string())
  println("PROBE lattice_total " + shape.total.to_string())
  println("PROBE lattice_first " + shape.first_position.to_string())
  println("PROBE lattice_last " + shape.last_position.to_string())
  println("PROBE lattice_max_digit " + shape.max_digit.to_string())
  assert_eq(shape.side, 4L)
  assert_eq(shape.total, 256L)
  assert_eq(shape.first_position, 1L)
  assert_eq(shape.last_position, 256L)
  assert_eq(shape.max_digit, 4L)

  // The entry. A `put` with the default spec lands in the default scope, never
  // expires, and has not been read yet — so its hit count is zero.
  let facts = match
    @tesseract_qa_contract_probe.entry_facts("probe-key", "probe-value") {
    Ok(f) => f
    Err(message) => {
      println("PROBE entry_error " + message)
      fail("the entry the probe wrote could not be read back")
    }
  }
  println("PROBE entry_scope " + facts.scope)
  println("PROBE entry_key " + facts.key)
  println("PROBE entry_value " + facts.value)
  println("PROBE entry_hits " + facts.hits.to_string())
  println("PROBE entry_sliding " + facts.sliding.to_string())
  assert_eq(facts.scope, "default")
  assert_eq(facts.key, "probe-key")
  assert_eq(facts.value, "probe-value")
  assert_eq(facts.hits, 0L)
  assert_eq(facts.sliding, false)
}

///|
/// The format's constants, as the published package declares them.
test "the format's constants are the ones the contract names" {
  println(
    "PROBE format_version " + @tesseract_memory_db.FORMAT_VERSION.to_string(),
  )
  println("PROBE header_key " + @tesseract_memory_db.HEADER_KEY)
  assert_eq(@tesseract_memory_db.FORMAT_VERSION, 1L)
  assert_eq(@tesseract_memory_db.HEADER_KEY, "tesseract-memory")
}

///|
/// A checkpoint written by this build is read back by this build.
///
/// The round trip is the contract's first duty: the file the writer writes has
/// to be the file the reader reads. The probe writes a checkpoint on a manual
/// clock, reopens it, and checks that both entries come back with their
/// values, and that the clock comes back with them.
test "a checkpoint written now is read back now" {
  let path = @tesseract_qa_contract_probe.probe_path("roundtrip.db")
  @tesseract_qa_contract_probe.write_checkpoint(
    path,
    @tesseract_memory.ttl_absolute(60000L),
  )
  println("PROBE roundtrip_path " + path)
  println(
    "PROBE header_value " + @tesseract_qa_contract_probe.read_header_value(path),
  )
  println(
    "PROBE header_row_key " + @tesseract_qa_contract_probe.read_header_key(path),
  )
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE roundtrip_open err")
      println("PROBE roundtrip_message " + message)
      fail("a checkpoint this build wrote was refused by this build")
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  let alpha = @tesseract_memory_db.DurableMemory::get(store, "alpha")
  let beta = @tesseract_memory_db.DurableMemory::get(store, "beta")
  let clock = @tesseract_memory_db.DurableMemory::memory(store).clock()
  println("PROBE roundtrip_open ok")
  println("PROBE roundtrip_entries " + entries.to_string())
  println(
    "PROBE roundtrip_alpha " + @tesseract_qa_contract_probe.opt_str(alpha),
  )
  println("PROBE roundtrip_beta " + @tesseract_qa_contract_probe.opt_str(beta))
  println("PROBE roundtrip_clock " + clock.name())
  println("PROBE roundtrip_now " + clock.read().to_string())
  assert_eq(entries, 2)
  assert_eq(alpha, Some("1"))
  assert_eq(beta, Some("2"))
  assert_eq(clock.name(), "manual")
  assert_eq(clock.read(), @tesseract_qa_contract_probe.PROBE_NOW)
}

///|
/// A checkpoint whose format version this build does not know is refused.
///
/// The format says so, in its own words: "A checkpoint that carries a version
/// this build does not know is refused rather than half-read: a store that
/// silently drops half of what it was given is worse than one that says it
/// cannot read the file."
///
/// The probe writes a checkpoint, changes the version in the header to a
/// number this build does not know, and reopens it. The entry that lives for a
/// minute is the tell: the checkpoint carries the manual clock it was written
/// on, and a reader that keeps the version but throws the clock away reads
/// that entry against the wall clock, where it is long dead.
test "a checkpoint with an unknown format version is refused" {
  let path = @tesseract_qa_contract_probe.probe_path("bad-version.db")
  @tesseract_qa_contract_probe.write_checkpoint(
    path,
    @tesseract_memory.ttl_absolute(60000L),
  )
  @tesseract_qa_contract_probe.rewrite_header_version(path, "2")
  println(
    "PROBE bad_version_header " +
    @tesseract_qa_contract_probe.read_header_value(path),
  )
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE bad_version_open err")
      println("PROBE bad_version_message " + message)
      return
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  let clock = @tesseract_memory_db.DurableMemory::memory(store).clock()
  println("PROBE bad_version_open ok")
  println("PROBE bad_version_entries " + entries.to_string())
  println("PROBE bad_version_clock " + clock.name())
  fail(
    "a checkpoint whose format version is unknown was accepted rather than refused",
  )
}

///|
/// A file whose header is not this format's header is refused.
///
/// The header's key is the file's identity: `read_header_cell` checks it and
/// gives up when it does not match. What it does **not** do is give up on the
/// rest of the file. The probe changes the header row's key and reopens the
/// file, with entries that never expire so that a lost clock cannot be
/// mistaken for the cause.
test "a file whose header key is not this format's is refused" {
  let path = @tesseract_qa_contract_probe.probe_path("bad-key.db")
  @tesseract_qa_contract_probe.write_checkpoint(
    path,
    @tesseract_memory.ttl_never(),
  )
  @tesseract_qa_contract_probe.rewrite_header_key(path, "some-other-tool")
  println(
    "PROBE bad_key_header_row_key " +
    @tesseract_qa_contract_probe.read_header_key(path),
  )
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE bad_key_open err")
      println("PROBE bad_key_message " + message)
      return
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  println("PROBE bad_key_open ok")
  println("PROBE bad_key_entries " + entries.to_string())
  fail(
    "a file whose header is not a tesseract-memory header was accepted as one",
  )
}

///|
/// A checkpoint with no header row at all is refused.
test "a checkpoint with no header row is refused" {
  let path = @tesseract_qa_contract_probe.probe_path("no-header.db")
  @tesseract_qa_contract_probe.write_checkpoint(
    path,
    @tesseract_memory.ttl_never(),
  )
  @tesseract_qa_contract_probe.delete_header_row(path)
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE no_header_open err")
      println("PROBE no_header_message " + message)
      return
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  println("PROBE no_header_open ok")
  println("PROBE no_header_entries " + entries.to_string())
  fail("a checkpoint with no header row was accepted as one")
}

///|
/// A file that is not a database at all is refused.
///
/// This is the case the format is clearest about: the file cannot be read, so
/// the store says so instead of opening an empty one.
test "a file that is not a checkpoint is refused" {
  let path = @tesseract_qa_contract_probe.probe_path("garbage.db")
  @tesseract_qa_contract_probe.write_garbage(path)
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE garbage_open err")
      println("PROBE garbage_message " + message)
      return
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  println("PROBE garbage_open ok")
  println("PROBE garbage_entries " + entries.to_string())
  fail("a file that is not a checkpoint was opened as an empty checkpoint")
}

///|
/// A file that is empty is not a refusal.
///
/// The format says a path that does not exist yet is not an error: the file is
/// created empty and the memory starts empty. An empty *file* is the same
/// thing as a missing one to a reader, so this is a measurement rather than a
/// contract: it records what the reader does so the report can say so.
test "an empty file opens as an empty store" {
  let path = @tesseract_qa_contract_probe.probe_path("empty.db")
  @tesseract_qa_contract_probe.write_empty(path)
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE empty_open err")
      println("PROBE empty_message " + message)
      return
    }
  }
  let entries = @tesseract_memory_db.DurableMemory::size(store)
  println("PROBE empty_open ok")
  println("PROBE empty_entries " + entries.to_string())
}

///|
/// A reload of a file with an unknown version half-reads it too.
///
/// `reload` replaces what the store holds with what the file holds, so a file
/// the reader does not understand empties the store as well.
///
/// The store is opened on a **good** file, and the file is corrupted
/// afterwards. That order matters: a build that refuses the bad file at the
/// open never reaches the reload, so a probe that only ever opened the bad
/// file would be measuring the open twice and the reload never. Opening the
/// good file first is the only way to reach the reload on a build that
/// refuses early — and to reach it at all is the point.
///
/// The corruption is read back before the reload, because a probe that
/// measured nothing must say so rather than pass.
test "a reload of a checkpoint with an unknown version is refused" {
  let path = @tesseract_qa_contract_probe.probe_path("reload-bad-version.db")
  @tesseract_qa_contract_probe.write_checkpoint(
    path,
    @tesseract_memory.ttl_never(),
  )
  let config = @tesseract_memory.default_config()
  let store = match @tesseract_memory_db.open(path, config) {
    Ok(s) => s
    Err(message) => {
      println("PROBE reload_open err")
      println("PROBE reload_message " + message)
      fail(
        "the good checkpoint could not be opened, so the reload was never measured",
      )
    }
  }
  let before = @tesseract_memory_db.DurableMemory::size(store)
  println("PROBE reload_open ok")
  println("PROBE reload_before " + before.to_string())
  @tesseract_qa_contract_probe.rewrite_header_version(path, "999")
  let header = @tesseract_qa_contract_probe.read_header_value(path)
  if !header.contains("999") {
    println("PROBE reload_corrupt failed")
    fail(
      "the header version could not be rewritten, so the reload was never measured",
    )
  }
  println("PROBE reload_corrupt ok")
  match @tesseract_memory_db.DurableMemory::reload(store) {
    Ok(n) => {
      println("PROBE reload_ok")
      println("PROBE reload_entries " + n.to_string())
      fail("a reload of a checkpoint with an unknown version was accepted")
    }
    Err(message) => {
      println("PROBE reload_err")
      println("PROBE reload_message " + message)
      let after = @tesseract_memory_db.DurableMemory::size(store)
      println("PROBE reload_after " + after.to_string())
      if after != before {
        fail("the store lost what it held when the reload was refused")
      }
    }
  }
}
