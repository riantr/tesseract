///|
/// The JSON path: how it is written, how it is refused, and what it reaches.
///
/// The old surface could only reach inside a document with `value LIKE
/// '%name%'` - a substring match. That cannot tell `{"name":"x"}` from
/// `{"other":"name"}`, cannot compare a number, and cannot follow a path.
///
/// Two rules decide everything here, and they are deliberately different rules:
///
/// - The **path** belongs to the statement. A malformed path is an error.
/// - The **value** belongs to the row. A row that is not JSON, or whose JSON
///   has no such key, answers `null`.

///|
/// The steps a path parses into, as text: `key:a,index:0`.
///
/// `JsonStep` has no `Eq`, so the steps are rendered rather than compared
/// directly. A rendered step also says more in a failure message than an index
/// alone would: "key:a" names the step, "index:0" does not say what it indexes.
fn steps_of(path : String) -> String {
  match @tesseract.json_path_parse(path) {
    Err(message) => "ERR " + message
    Ok(steps) => {
      let parts : Array[String] = []
      for step in steps {
        let text = match step {
          @tesseract.JsonStep::Key(k) => "key:" + k
          @tesseract.JsonStep::Index(i) => "index:" + i.to_string()
        }
        parts.push(text)
      }
      parts.join(",")
    }
  }
}

///|
/// A SQL value as the text a result would carry.
fn sql_text(v : @tesseract.SqlValue) -> String {
  match v {
    Null => "NULL"
    Int(n) => n.to_string()
    Text(t) => t
  }
}

///|
/// The value a path reaches in a document, as SQL text, or `NULL` for a miss.
fn at(document : String, path : String) -> String {
  let steps = match @tesseract.json_path_parse(path) {
    Err(message) => return "ERR " + message
    Ok(s) => s
  }
  let parsed = @json.parse(document) catch { _ => return "BAD JSON" }
  match @tesseract.json_walk(parsed, steps) {
    None => "NULL"
    Some(v) => sql_text(@tesseract.json_to_sql(v))
  }
}

///|
/// A whole number, as text, or "not a whole number".
fn whole(text : String) -> String {
  match @tesseract.json_whole_number(text) {
    None => "not a whole number"
    Some(n) => n.to_string()
  }
}

///|
/// A path is read as the steps it names.
///
/// The grammar is deliberately small - `$`, `.name`, `[n]`, `["name"]` - because
/// a larger grammar is a second language to learn, and this is the part that
/// answers real questions about a document.
test "a path is read as the steps it names" {
  assert_eq(steps_of("$"), "")
  assert_eq(steps_of("$.a"), "key:a")
  assert_eq(steps_of("$.a.b"), "key:a,key:b")
  assert_eq(steps_of("$.a[0]"), "key:a,index:0")
  assert_eq(steps_of("$.a[0].b"), "key:a,index:0,key:b")
  // A name that is not an identifier has to be quoted, and either quote works.
  assert_eq(steps_of("$[\"a b\"]"), "key:a b")
  assert_eq(steps_of("$['a b']"), "key:a b")
  // `-` and `_` are name characters, so this is one key and not two.
  assert_eq(steps_of("$.a-b_c9"), "key:a-b_c9")
}

///|
/// A malformed path is refused, and the refusal says what is wrong with it.
///
/// The message matters more than it looks: a path is the one part of a
/// `json_extract` call that is the same for every row, so it is the one part
/// that can be checked without the data. "json path has a '[' that is not an
/// index or a quoted name" tells the writer which character to look at.
test "a malformed path is refused, and the refusal says what is wrong with it" {
  assert_eq(steps_of(""), "ERR json path is empty")
  assert_eq(steps_of("a.b"), "ERR json path must start with '$'")
  assert_eq(steps_of("$."), "ERR json path ends with '.'")
  assert_eq(
    steps_of("$.a!"),
    "ERR json path has a character that is not part of a step",
  )
  assert_eq(steps_of("$.a["), "ERR json path ends with '['")
  assert_eq(steps_of("$[\"a"), "ERR json path has an unterminated quoted name")
  assert_eq(
    steps_of("$[\"a\"x"),
    "ERR json path has a quoted name not closed by ']'",
  )
  assert_eq(
    steps_of("$.a[x]"),
    "ERR json path has a '[' that is not an index or a quoted name",
  )
  assert_eq(steps_of("$.a[0"), "ERR json path has an index not closed by ']'")
}

///|
/// A path that does not exist has no value, and that is not an error.
///
/// Asking for `$.a.b` of a document whose `a` is a number has no answer. The
/// honest one is null, and the difference from a *malformed* path is the whole
/// point: one is the data's business and the other is the writer's.
test "a path that does not exist has no value" {
  let doc = "{\"a\":{\"b\":[10,20]},\"n\":null,\"t\":true}"
  assert_eq(at(doc, "$.a.b[0]"), "10")
  assert_eq(at(doc, "$.a.b[1]"), "20")
  // Past the end of the array.
  assert_eq(at(doc, "$.a.b[2]"), "NULL")
  // A key applied to an array, and a key that is simply not there.
  assert_eq(at(doc, "$.a.b.deeper"), "NULL")
  assert_eq(at(doc, "$.a.missing"), "NULL")
  assert_eq(at(doc, "$.missing.deeper"), "NULL")
  // A null in the document is a null, and a boolean is a 1.
  assert_eq(at(doc, "$.n"), "NULL")
  assert_eq(at(doc, "$.t"), "1")
}

///|
/// A container comes back as its JSON text, so it can be fed back in.
///
/// This is what makes `json_extract` compose: the value of a path that lands on
/// an object is the object itself, written as JSON, and that text is a legal
/// input to another `json_extract`.
test "a container comes back as its JSON text, so it can be fed back in" {
  let doc = "{\"a\":{\"b\":[10,20]},\"n\":null,\"t\":true}"
  assert_eq(at(doc, "$.a.b"), "[10,20]")
  assert_eq(at(at(doc, "$.a"), "$.b[1]"), "20")
  assert_eq(at(at(doc, "$.a.b"), "$[0]"), "10")
}

///|
/// A whole number is read at full 64-bit width, from the text.
///
/// The text is parsed rather than the double, because a double cannot hold a
/// 64-bit integer exactly: `9007199254740993` is one more than `2^53`, and
/// reading it as a double would change it by one without saying so.
test "a whole number is read at full 64-bit width" {
  assert_eq(whole("0"), "0")
  assert_eq(whole("25"), "25")
  assert_eq(whole("-3"), "-3")
  // A whole number however it was spelled.
  assert_eq(whole("25.0"), "25")
  assert_eq(whole("25.00"), "25")
  // The case a double would get wrong.
  assert_eq(whole("9007199254740993"), "9007199254740993")
  assert_eq(whole("999999999999999999"), "999999999999999999")
  // Not whole numbers, and not numbers at all.
  assert_eq(whole("2.5"), "not a whole number")
  assert_eq(whole("0.1"), "not a whole number")
  assert_eq(whole("2.5e3"), "not a whole number")
  assert_eq(whole("1e2"), "not a whole number")
  // Nineteen digits can overflow a 64-bit integer, so they are not read as one.
  assert_eq(whole("12345678901234567890"), "not a whole number")
  assert_eq(whole(""), "not a whole number")
  assert_eq(whole("-"), "not a whole number")
}

///|
/// A number that is not a whole number keeps its own text.
///
/// `SqlValue` has no floating-point variant, so `2.5` cannot be a number here.
/// It stays the text it was written as - not a double's idea of it - so nothing
/// is rounded and nothing is invented.
test "a number that is not a whole number keeps its own text" {
  assert_eq(at("{\"f\":2.5}", "$.f"), "2.5")
  assert_eq(at("{\"f\":0.1}", "$.f"), "0.1")
  assert_eq(at("{\"f\":9007199254740993}", "$.f"), "9007199254740993")
}
