///|
/// The checkpoint format.
///
/// A checkpoint is a **lattice**, and each cell of it holds one JSON object.
/// The first cell is the header — the format version and the clock — and the
/// cells after it hold the entries, one each.
///
/// The JSON is written with the toolchain's own writer, so the escaping is the
/// escaping JSON is supposed to have. Two details of it matter here:
///
/// - **An `Int64` is written as a JSON string**, not as a number. JSON numbers
///   are doubles, and a deadline can be `9223372036854775807` — the largest
///   instant the store can express — which a double cannot hold exactly. A
///   string can, so the deadline comes back as the deadline it was.
/// - **A `Double` is written as a JSON number**, because an importance of 0.5
///   is a number and reads better as one.
///
/// The entry carries its **absolute** deadline, not the lifetime it was given.
/// A lifetime is relative to the moment of the write, and a checkpoint that
/// stored one would move every deadline forward by however long the store was
/// closed. The absolute deadline is the fact; the lifetime is a way of
/// arriving at it.
///
/// The metadata is a list of `{"k": ..., "v": ...}` pairs, because that is what
/// a pair is: a key and a value, in that order.
pub const HEADER_KEY : String = "tesseract-memory"

///|
/// The version of the format this build writes.
///
/// A checkpoint that carries a version this build does not know is refused
/// rather than half-read: a store that silently drops half of what it was
/// given is worse than one that says it cannot read the file.
pub const FORMAT_VERSION : Int64 = 1L

///|
/// The header of a checkpoint: the format version and the clock.
fn encode_header(clock : @tesseract_memory.MemoryClock) -> String {
  let obj : Map[String, @builtin.Json] = Map([])
  obj.set("format", @json.to_json(FORMAT_VERSION))
  if clock.is_manual() {
    obj.set("clock", @json.to_json("manual"))
    obj.set("now", @json.to_json(clock.read()))
  } else {
    obj.set("clock", @json.to_json("system"))
  }
  @json.to_json(obj).stringify()
}

///|
/// The clock a checkpoint carries, or the reason it cannot be read.
///
/// A header that names a format version this build does not know is refused
/// rather than half-read, which is what `FORMAT_VERSION` promises. The
/// difference is not academic: a store that read it anyway would come back
/// on a different clock, and every entry the file's own clock had already
/// expired would be gone without a word — a store that silently drops half
/// of what it was given, which is the thing the promise was made to prevent.
fn decode_header(
  text : String,
) -> Result[@tesseract_memory.MemoryClock, String] {
  let obj = match parse_object(text) {
    Some(o) => o
    None => return Err("the header cell is not a JSON object")
  }
  let version = field_int(obj, "format")
  if version != FORMAT_VERSION {
    return Err(
      "the checkpoint carries format version " +
      version.to_string() +
      " and this build reads version " +
      FORMAT_VERSION.to_string(),
    )
  }
  match field_str(obj, "clock") {
    "system" => Ok(@tesseract_memory.memory_clock_system())
    "manual" =>
      match parse_i64(field_str(obj, "now")) {
        Some(now) => Ok(@tesseract_memory.memory_clock_manual(now))
        None =>
          Err("the checkpoint carries a manual clock with no readable instant")
      }
    other =>
      Err(
        "the checkpoint names a clock this build does not know: '" + other + "'",
      )
  }
}

///|
/// One entry, as the JSON object a cell holds.
fn encode_entry(entry : @tesseract_memory.Entry) -> String {
  let obj : Map[String, @builtin.Json] = Map([])
  obj.set("scope", @json.to_json(entry.scope()))
  obj.set("key", @json.to_json(entry.key()))
  obj.set("value", @json.to_json(entry.value()))
  obj.set("added_at", @json.to_json(entry.added_at()))
  obj.set("deadline", @json.to_json(entry.deadline()))
  obj.set("window_ms", @json.to_json(entry.window_ms()))
  obj.set("sliding", @json.to_json(entry.sliding()))
  obj.set("last_seen", @json.to_json(entry.last_seen()))
  obj.set("hits", @json.to_json(entry.hits()))
  obj.set("importance", @json.to_json(entry.importance()))
  obj.set("pinned", @json.to_json(entry.pinned()))
  let pairs : Array[@builtin.Json] = []
  for (k, v) in entry.metadata().pairs() {
    let pair : Map[String, @builtin.Json] = Map([])
    pair.set("k", @json.to_json(k))
    pair.set("v", @json.to_json(v))
    pairs.push(@json.to_json(pair))
  }
  obj.set("metadata", @json.to_json(pairs))
  @json.to_json(obj).stringify()
}

///|
/// The entry a cell holds, or `None` when the cell does not hold one this
/// build can read.
///
/// A cell that cannot be read is a cell that is skipped rather than a load
/// that fails: one unreadable entry among a hundred is not a reason to lose
/// the other ninety-nine, and the entry it was is one the store would have
/// dropped anyway.
fn decode_entry(text : String) -> @tesseract_memory.Entry? {
  let obj = match parse_object(text) {
    Some(o) => o
    None => return None
  }
  let key = field_str(obj, "key")
  if key == "" {
    return None
  }
  let pairs : Array[(String, String)] = []
  match obj.get("metadata") {
    Some(v) =>
      match v {
        @builtin.Json::Array(items) =>
          for item in items {
            match item {
              @builtin.Json::Object(p) =>
                pairs.push((field_str(p, "k"), field_str(p, "v")))
              _ => ()
            }
          }
        _ => ()
      }
    None => ()
  }
  Some(
    @tesseract_memory.Entry::make(
      field_str(obj, "scope"),
      key,
      field_str(obj, "value"),
      field_int(obj, "added_at"),
      field_int(obj, "deadline"),
      field_int(obj, "window_ms"),
      field_bool(obj, "sliding"),
      field_int(obj, "last_seen"),
      field_int(obj, "hits"),
      field_double(obj, "importance"),
      @tesseract_memory.new_metadata(pairs),
      field_bool(obj, "pinned"),
    ),
  )
}

///|
/// The object a piece of JSON is, or `None` when it is not an object.
fn parse_object(text : String) -> Map[String, @builtin.Json]? {
  let parsed = @json.parse(text) catch { _ => return None }
  match parsed {
    @builtin.Json::Object(obj) => Some(obj)
    _ => None
  }
}

///|
/// The string at a key, or `""` when there is none.
fn field_str(obj : Map[String, @builtin.Json], key : String) -> String {
  match obj.get(key) {
    Some(v) =>
      match v {
        @builtin.Json::String(s) => s
        _ => ""
      }
    None => ""
  }
}

///|
/// The integer at a key, or `0L` when there is none.
///
/// The value is read from a string, because that is how an `Int64` is
/// written: a JSON number is a double, and the largest deadline the store can
/// express does not fit in one.
fn field_int(obj : Map[String, @builtin.Json], key : String) -> Int64 {
  match parse_i64(field_str(obj, key)) {
    Some(n) => n
    None => 0L
  }
}

///|
/// A whole number out of decimal text.
///
/// The toolchain's own `parse_int` reads an `Int32`, and a deadline does not
/// fit in one — a millisecond timestamp is past two billion only in 1970. So
/// this reads the digits itself, and it refuses anything it cannot hold
/// exactly: a number that does not fit is not a number, and a number that is
/// quietly wrong is worse.
///
/// Only whole numbers are read. Every field this is used for is a count, a
/// time or a size, and none of them is ever negative.
fn parse_i64(text : String) -> Int64? {
  if text == "" {
    return None
  }
  let mut value = 0L
  let mut i = 0
  while i < text.length() {
    let code = text.at(i).to_int()
    if code < 48 || code > 57 {
      return None
    }
    let digit = (code - 48).to_int64()
    // The largest value that can still take one more digit, and then some.
    if value > (9223372036854775807L - digit) / 10L {
      return None
    }
    value = value * 10L + digit
    i = i + 1
  }
  Some(value)
}

///|
/// The flag at a key, or `false` when there is none.
fn field_bool(obj : Map[String, @builtin.Json], key : String) -> Bool {
  match obj.get(key) {
    Some(v) =>
      match v {
        @builtin.Json::True => true
        _ => false
      }
    None => false
  }
}

///|
/// The number at a key, or `0.0` when there is none.
fn field_double(obj : Map[String, @builtin.Json], key : String) -> Double {
  match obj.get(key) {
    Some(v) =>
      match v {
        @builtin.Json::Number(n, repr=_) => n
        _ => 0.0
      }
    None => 0.0
  }
}
