///|
/// The engine: a parsed statement in, a `DBResponse` out.
///
/// What replaces what: `sql.mbt` was 932 lines that repeatedly re-scanned the raw
/// statement text, and its `Where` was a struct holding at most one predicate per
/// field. Four measured consequences followed from that shape, and two of them
/// were silent - a clause that parsed as nothing and was dropped, so the query
/// answered a different question than the one asked and reported success:
///
/// | statement | the old surface | this one |
/// |---|---|---|
/// | `WHERE key='alpha' AND key='beta'` | 1 row, `beta` | 0 rows |
/// | `WHERE key='alpha' OR key='beta'` | `INVALID_SYNTAX` | 1 row |
/// | `SELECT ... LIMIT 1` | **3 rows** | 1 row |
/// | `SELECT ... ORDER BY key DESC` | **insertion order** | sorted |
/// | `WHERE digit=1+1` | `INVALID_SYNTAX` | digit 2 |
///
/// The rule that follows from those two silent rows is not "be careful" - it is
/// **a clause the parser accepts is a clause this file applies, or the statement
/// is refused.** There is no path below that parses a clause and drops it.
///
/// Everything here is three-valued. `SqlValue::Null` is unknown, `AND`/`OR`/
/// `NOT` propagate it the way SQL does, and `WHERE` keeps a row only on a known
/// true. Booleans are `SqlValue::Int(0|1)` so one evaluator serves predicates and
/// arithmetic alike; a second evaluator would be a second thing to get wrong.

///|
/// The outcome of evaluating one node.
///
/// No `?` propagation operator in this toolchain, so a fallible evaluator returns
/// a two-case type. That also keeps the error intact: `Failed` carries the whole
/// response, so a refusal keeps its code and message instead of degrading to a
/// boolean that later reads as a legitimate answer.
priv enum Eval {
  Value(SqlValue)
  Failed(DBResponse)
}

///|
/// Runs one statement against `db`.
///
/// Transaction statements are deliberately **not** wrapped in the implicit
/// statement savepoint the DML statements get: their whole job is to manage that
/// journal, so aborting a failed `COMMIT` would undo the transaction it was meant
/// to end.
pub fn execute(db : Tesseract, sql : String) -> DBResponse {
  let mut text = trim_ws(sql)
  while text.length() > 0 && text.at(text.length() - 1) == ';' {
    text = trim_ws(slice(text, 0, text.length() - 1))
  }
  if text == "" {
    return err_response("EMPTY_SQL", "No SQL statement")
  }
  let parsed = match parse_statement(text) {
    Ok(s) => s
    Err(e) =>
      return err_response(
        e.code,
        e.message + " (at offset " + e.at.to_string() + ")",
      )
  }
  match parsed {
    Begin | Commit | Rollback | Savepoint(_) | RollbackTo(_) | Release(_) =>
      run_stmt(db, parsed)
    _ => {
      let mark = Tesseract::journal_depth(db)
      let result = run_stmt(db, parsed)
      if result.success {
        Tesseract::statement_commit(db, mark)
      } else {
        Tesseract::statement_abort(db, mark)
      }
      result
    }
  }
}

///|
/// Dispatches one parsed statement.
fn run_stmt(db : Tesseract, s : Stmt) -> DBResponse {
  match s {
    CreateDatabase(_) => ok_response("CREATE_DATABASE")
    Insert(cols, values, target) => run_insert(db, cols, values, target)
    Update(sets, filter) => run_update(db, sets, filter)
    Delete(filter) => run_delete(db, filter)
    Select(spec) => run_select(db, spec)
    Begin => Tesseract::begin(db)
    Commit => Tesseract::commit(db)
    Rollback => Tesseract::rollback(db)
    Savepoint(name) => Tesseract::savepoint(db, name)
    RollbackTo(name) => Tesseract::rollback_to(db, name)
    Release(name) => Tesseract::release_savepoint(db, name)
  }
}

// ---------------------------------------------------------------------------
// Reading rows
// ---------------------------------------------------------------------------

///|
/// Every occupied cell, as a row, in position order.
fn all_rows(db : Tesseract) -> Array[Record] {
  let rows : Array[Record] = []
  let mut i = 0
  while i < db.cells.length() {
    if !cell_is_empty(db.cells[i]) {
      rows.push(to_record(db.lattice, db.cells[i]))
    }
    i = i + 1
  }
  rows
}

///|
/// The rows a `WHERE` expression keeps, or the reason it cannot be answered.
///
/// Unknown reads as false, which is SQL's rule for a filter. A filter that cannot
/// be evaluated at all - a bad axis, an unknown function - fails the statement.
/// `SELECT * FROM t WHERE line(1, 9)` returning every row would be the
/// silent-clause failure this file exists to remove, in the one place it would be
/// hardest to notice.
fn filter_rows(
  db : Tesseract,
  rows : Array[Record],
  filter : Expr?,
) -> (Array[Record], DBResponse?) {
  match filter {
    None => (rows, None)
    Some(e) => {
      let checked = validate_filter(db, e)
      if checked is Some(_) {
        let r = checked.unwrap()
        return ([], Some(r))
      }
      let kept : Array[Record] = []
      for row in rows {
        match eval_value(db, e, Some(row), [row]) {
          Value(v) => if truthy(v) { kept.push(row) }
          Failed(r) => return ([], Some(r))
        }
      }
      (kept, None)
    }
  }
}

///|
/// A row that exists only to be evaluated against.
///
/// Used to prove an expression is *evaluable* when there is no data to evaluate
/// it on. `SELECT * FROM t WHERE bogus = 'x'` on an empty table used to succeed
/// and answer zero rows, because a filter is only ever evaluated against rows and
/// there were none - so an unknown column was accepted on an empty table and
/// refused on a full one. The statement is wrong regardless of the data, so the
/// data cannot decide whether it is.
fn probe_row(db : Tesseract) -> Record {
  let lat = db.lattice
  {
    key: "",
    value: "",
    position: lat.first_position,
    coords: coords_of(lat, lat.first_position).unwrap(),
    timestamp: "",
    digit: NO_DIGIT,
    computed: [],
  }
}

///|
/// Evaluates a filter once against a row that does not exist, and reports only
/// whether it could be evaluated at all.
///
/// The answer is discarded. An `OR` whose left side is true never evaluates its
/// right side, so a broken expression on that side would otherwise survive every
/// row in the table; the probe evaluates the whole tree.
fn validate_filter(db : Tesseract, filter : Expr) -> DBResponse? {
  let probe = probe_row(db)
  match eval_value(db, filter, Some(probe), [probe]) {
    Value(_) => None
    Failed(r) => Some(r)
  }
}

///|
/// Refuses a column this table does not have, anywhere in the clauses of a
/// `SELECT`, before a single row is read.
///
/// `WHERE` has always been checked this way, against a synthetic row, because a
/// statement that is wrong regardless of the data cannot be validated by the
/// data. The same argument applies to the clauses that had no such check, and
/// there the failure was worse than an error, because it was not an error:
///
/// - `GROUP BY nosuchcol` evaluated the unknown column to null on every row, so
///   every row hashed to one group and the query answered *one group* — the same
///   shape a legitimately uniform column answers, so nothing in the result said
///   the column did not exist.
/// - `ORDER BY nosuchcol` sorted on that null and returned rows in the order
///   they were stored, which is also what a uniform column returns.
/// - A plain column in a grouped select list was worse still: `group_rows` takes
///   the `plain_column` branch for a bare name and never evaluates it, so it
///   reached `project` unchecked and was dropped there in silence.
///
/// Only `Column` nodes are checked. Everything else is left to `eval_value`,
/// which already reports unknown functions and type errors against a real row;
/// checking aggregates here too would mean inventing a second notion of what
/// `count(*)` means before the executor has a group to count.
fn validate_select_columns(db : Tesseract, spec : SelectSpec) -> DBResponse? {
  if !spec.star {
    for c in spec.columns {
      match check_columns(db, c) {
        Some(r) => return Some(r)
        None => ()
      }
    }
  }
  for t in spec.group_by {
    match check_columns(db, t) {
      Some(r) => return Some(r)
      None => ()
    }
  }
  for t in spec.order_by {
    match check_columns(db, t.expr) {
      Some(r) => return Some(r)
      None => ()
    }
  }
  None
}

///|
/// Every `Column` in one expression tree must name a real column.
///
/// The probe row is built once per call and threaded through, so a nested
/// expression re-validates against the same row rather than allocating a new
/// one at every leaf.
fn check_columns(db : Tesseract, expr : Expr) -> DBResponse? {
  check_columns_with(db, expr, probe_row(db))
}

///|
fn check_columns_with(
  db : Tesseract,
  expr : Expr,
  probe : Record,
) -> DBResponse? {
  match expr {
    Column(name) =>
      match eval_column(db, name, Some(probe)) {
        Value(_) => None
        Failed(r) => Some(r)
      }
    Not(inner) => check_columns_with(db, inner, probe)
    Neg(inner) => check_columns_with(db, inner, probe)
    IsNull(inner, _) => check_columns_with(db, inner, probe)
    Binary(_, a, b) =>
      match check_columns_with(db, a, probe) {
        Some(r) => Some(r)
        None => check_columns_with(db, b, probe)
      }
    Like(a, b) =>
      match check_columns_with(db, a, probe) {
        Some(r) => Some(r)
        None => check_columns_with(db, b, probe)
      }
    In(head, list) =>
      match check_columns_with(db, head, probe) {
        Some(r) => Some(r)
        None => check_columns_in_list(db, list, probe)
      }
    Call(_, args) => check_columns_in_list(db, args, probe)
    Literal(_) => None
    Star => None
  }
}

///|
fn check_columns_in_list(
  db : Tesseract,
  list : Array[Expr],
  probe : Record,
) -> DBResponse? {
  let mut i = 0
  while i < list.length() {
    match check_columns_with(db, list[i], probe) {
      Some(r) => return Some(r)
      None => ()
    }
    i = i + 1
  }
  None
}

///|
/// A value read as a condition: `1` and non-empty text are true, `0` and empty
/// text false, `Null` unknown.
fn truthy(v : SqlValue) -> Bool {
  match v {
    Null => false
    Int(n) => n != 0L
    Text(t) => t != ""
  }
}

///|
/// `1` or `0`.
fn bool_value(b : Bool) -> SqlValue {
  Int(if b { 1L } else { 0L })
}

///|
/// A value rendered as text, for a `Computed` cell and for error messages.
fn render(v : SqlValue) -> String {
  match v {
    Null => "NULL"
    Int(n) => n.to_string()
    Text(t) => t
  }
}

///|
/// Reads a value as an integer, or says why not.
fn as_int(v : SqlValue) -> Result[Int64, String] {
  match v {
    Int(n) => Ok(n)
    Text(t) =>
      match parse_int(t) {
        Some(n) => Ok(n.to_int64())
        None => Err("expected an integer, got '" + t + "'")
      }
    Null => Err("expected an integer, got NULL")
  }
}

// ---------------------------------------------------------------------------
// Expression evaluation
// ---------------------------------------------------------------------------

///|
/// Evaluates one expression node.
fn eval_value(
  db : Tesseract,
  e : Expr,
  row : Record?,
  group : Array[Record],
) -> Eval {
  match e {
    Literal(v) => Value(v)
    Star => Value(Int(1L))
    Column(name) => eval_column(db, lower(name), row)
    Neg(inner) =>
      match eval_value(db, inner, row, group) {
        Failed(r) => Failed(r)
        Value(v) =>
          match as_int(v) {
            Err(message) => Failed(err_response("INVALID_INPUT", message))
            Ok(n) => Value(Int(-n))
          }
      }
    Not(inner) =>
      match eval_bool(db, inner, row, group) {
        Some(b) => Value(bool_value(!b))
        None => Value(Null)
      }
    Binary(op, a, b) => eval_binary(db, op, a, b, row, group)
    Like(a, b) => eval_like(db, a, b, row, group)
    In(a, list) => eval_in(db, a, list, row, group)
    IsNull(a, negated) =>
      match eval_value(db, a, row, group) {
        Failed(r) => Failed(r)
        // `negated` is true for `IS NOT NULL`, so the two answers are the other
        // way round from the flag: a null value satisfies `IS NULL` and fails
        // `IS NOT NULL`, and a value that is not null does the opposite. These
        // two lines were the wrong way round - `Value(Null)` answered
        // `bool_value(negated)` - and nothing caught it, because the parser test
        // only checked the *shape* of the node and no executor test asked what
        // the predicate answered. `IS NULL` returned every row that had a value
        // and no row that had none, and `IS NOT NULL` did the reverse.
        Value(Null) => Value(bool_value(!negated))
        Value(_) => Value(bool_value(negated))
      }
    Call(name, args) => eval_call(db, lower(name), args, row, group)
  }
}

///|
/// One truth value, or `None` for unknown.
///
/// The three-valued rules are written out rather than looked up in a table,
/// because the two cases that are easy to get wrong are both here: `false AND
/// unknown` is *false*, not unknown, and `unknown OR false` is *unknown*, not
/// false.
fn eval_bool(
  db : Tesseract,
  e : Expr,
  row : Record?,
  group : Array[Record],
) -> Bool? {
  match e {
    Binary("AND", a, b) => {
      let x = eval_bool(db, a, row, group)
      let y = eval_bool(db, b, row, group)
      if x == Some(false) || y == Some(false) {
        Some(false)
      } else if x == Some(true) && y == Some(true) {
        Some(true)
      } else {
        None
      }
    }
    Binary("OR", a, b) => {
      let x = eval_bool(db, a, row, group)
      let y = eval_bool(db, b, row, group)
      if x == Some(true) || y == Some(true) {
        Some(true)
      } else if x == Some(false) && y == Some(false) {
        Some(false)
      } else {
        None
      }
    }
    other =>
      match eval_value(db, other, row, group) {
        Failed(_) => Some(false)
        Value(Null) => None
        Value(v) => Some(truthy(v))
      }
  }
}

///|
/// One named column of the row.
fn eval_column(db : Tesseract, name : String, row : Record?) -> Eval {
  match row {
    None =>
      Failed(
        err_response("INVALID_COLUMNS", "No row in context for column " + name),
      )
    Some(r) =>
      if name == "key" {
        Value(Text(r.key))
      } else if name == "value" {
        Value(Text(r.value))
      } else if name == "position" || name == "grid_position" {
        Value(Int(r.position))
      } else if name == "digit" {
        Value(Int(r.digit))
      } else if name == "timestamp" {
        Value(Text(r.timestamp))
      } else if name == "x" {
        Value(Int(coord_at_unchecked(r.coords, 0L)))
      } else if name == "y" {
        Value(Int(coord_at_unchecked(r.coords, 1L)))
      } else if name == "z" {
        Value(Int(coord_at_unchecked(r.coords, 2L)))
      } else if name == "w" {
        Value(Int(coord_at_unchecked(r.coords, 3L)))
      } else if name == "side" {
        Value(Int(db.lattice.side))
      } else {
        Failed(
          err_response(
            "INVALID_COLUMNS",
            "Unknown column " +
            name +
            "; this table has key, value, position, digit, timestamp, x, y, z, w, side",
          ),
        )
      }
  }
}

///|
/// One binary operator.
fn eval_binary(
  db : Tesseract,
  op : String,
  a : Expr,
  b : Expr,
  row : Record?,
  group : Array[Record],
) -> Eval {
  // Boolean operators go to `eval_bool` so the three-valued rules apply. Routing
  // them through `Int(0|1)` first would make `unknown AND false` come out false
  // by accident rather than by the rule.
  if op == "AND" || op == "OR" {
    return match eval_bool(db, Binary(op, a, b), row, group) {
      Some(b) => Value(bool_value(b))
      None => Value(Null)
    }
  }
  let left = eval_value(db, a, row, group)
  let right = eval_value(db, b, row, group)
  let lv = match left {
    Failed(r) => return Failed(r)
    Value(v) => v
  }
  let rv = match right {
    Failed(r) => return Failed(r)
    Value(v) => v
  }
  if op == "+" || op == "-" || op == "*" || op == "/" || op == "%" {
    return arithmetic(op, lv, rv)
  }
  match comparable(lv, rv) {
    Err(message) => Failed(err_response("INVALID_INPUT", message))
    // Unknown compares unknown, even against itself: `NULL = NULL` is not true.
    Ok((Null, _)) | Ok((_, Null)) => Value(Null)
    Ok((x, y)) => Value(compare_op(op, x, y))
  }
}

///|
/// Puts both sides of a comparison in one type.
///
/// `WHERE digit = '1'` has to keep working: the C# exporter wrote numbers as
/// quoted literals and the old parser ran `parse_int` on the right-hand side, so
/// a quoted integer was always accepted against an integer column. Text that does
/// not parse stays a type error rather than being compared as text, because
/// string ordering would answer a question nobody asked.
fn comparable(
  a : SqlValue,
  b : SqlValue,
) -> Result[(SqlValue, SqlValue), String] {
  match (a, b) {
    (Null, _) | (_, Null) => Ok((Null, Null))
    (Int(_), Int(_)) => Ok((a, b))
    (Text(_), Text(_)) => Ok((a, b))
    (Int(m), Text(t)) =>
      match parse_int(t) {
        Some(n) => Ok((Int(m), Int(n.to_int64())))
        None => Err("cannot compare an integer with the text " + t)
      }
    (Text(t), Int(n)) =>
      match parse_int(t) {
        Some(m) => Ok((Int(m.to_int64()), Int(n)))
        None => Err("cannot compare the text " + t + " with an integer")
      }
  }
}

///|
fn arithmetic(op : String, a : SqlValue, b : SqlValue) -> Eval {
  if a == Null || b == Null {
    return Value(Null)
  }
  let m = match as_int(a) {
    Err(message) => return Failed(err_response("INVALID_INPUT", message))
    Ok(v) => v
  }
  let n = match as_int(b) {
    Err(message) => return Failed(err_response("INVALID_INPUT", message))
    Ok(v) => v
  }
  if (op == "/" || op == "%") && n == 0L {
    return Failed(err_response("INVALID_INPUT", "Division by zero"))
  }
  match op {
    "+" => Value(Int(m + n))
    "-" => Value(Int(m - n))
    "*" => Value(Int(m * n))
    "/" => Value(Int(m / n))
    "%" => Value(Int(m % n))
    _ => Failed(err_response("INVALID_SYNTAX", "Unknown operator " + op))
  }
}

///|
fn compare_op(op : String, a : SqlValue, b : SqlValue) -> SqlValue {
  let c = compare_values(a, b)
  let r = if op == "=" {
    c == 0
  } else if op == "<>" {
    c != 0
  } else if op == "<" {
    c < 0
  } else if op == "<=" {
    c <= 0
  } else if op == ">" {
    c > 0
  } else if op == ">=" {
    c >= 0
  } else {
    false
  }
  bool_value(r)
}

///|
/// Orders two same-typed values: integers numerically, text by code unit.
fn compare_values(a : SqlValue, b : SqlValue) -> Int32 {
  match (a, b) {
    (Int(m), Int(n)) => if m < n { -1 } else if m > n { 1 } else { 0 }
    (Text(s), Text(t)) => {
      let n = if s.length() < t.length() { s.length() } else { t.length() }
      let mut i = 0
      while i < n {
        let x = s.at(i)
        let y = t.at(i)
        if x != y {
          return if x < y { -1 } else { 1 }
        }
        i = i + 1
      }
      if s.length() == t.length() {
        0
      } else if s.length() < t.length() {
        -1
      } else {
        1
      }
    }
    _ => 0
  }
}

///|
fn eval_like(
  db : Tesseract,
  a : Expr,
  b : Expr,
  row : Record?,
  group : Array[Record],
) -> Eval {
  let lv = match eval_value(db, a, row, group) {
    Failed(r) => return Failed(r)
    Value(v) => v
  }
  let rv = match eval_value(db, b, row, group) {
    Failed(r) => return Failed(r)
    Value(v) => v
  }
  if lv == Null || rv == Null {
    return Value(Null)
  }
  match rv {
    Text(pattern) => Value(bool_value(like_matches(render(lv), pattern)))
    other =>
      Failed(
        err_response(
          "INVALID_INPUT",
          "LIKE needs a text pattern, got " + render(other),
        ),
      )
  }
}

///|
fn eval_in(
  db : Tesseract,
  a : Expr,
  list : Array[Expr],
  row : Record?,
  group : Array[Record],
) -> Eval {
  let lv = match eval_value(db, a, row, group) {
    Failed(r) => return Failed(r)
    Value(v) => v
  }
  if lv == Null {
    return Value(Null)
  }
  let mut saw_null = false
  let mut hit = false
  for item in list {
    let other = match eval_value(db, item, row, group) {
      Failed(r) => return Failed(r)
      Value(v) => v
    }
    match comparable(lv, other) {
      Err(message) => return Failed(err_response("INVALID_INPUT", message))
      Ok((Null, _)) | Ok((_, Null)) => saw_null = true
      Ok((x, y)) => if compare_values(x, y) == 0 { hit = true }
    }
  }
  if hit {
    Value(bool_value(true))
  } else if saw_null {
    Value(Null)
  } else {
    Value(bool_value(false))
  }
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

///|
fn is_aggregate(name : String) -> Bool {
  name == "count" ||
  name == "sum" ||
  name == "min" ||
  name == "max" ||
  name == "avg"
}

///|
/// One scalar, geometry or aggregate function.
fn eval_call(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  row : Record?,
  group : Array[Record],
) -> Eval {
  if is_aggregate(name) {
    return aggregate(db, name, args, group)
  }
  match name {
    "length" =>
      scalar1(db, name, args, row, group, fn(v) {
        match v {
          Null => Value(Null)
          other => Value(Int(render(other).length().to_int64()))
        }
      })
    "upper" => text1(db, name, args, row, group, upper)
    "lower" => text1(db, name, args, row, group, lower)
    "abs" =>
      scalar1(db, name, args, row, group, fn(v) {
        match as_int(v) {
          Err(message) => Failed(err_response("INVALID_INPUT", message))
          Ok(n) => Value(if n < 0L { Int(-n) } else { Int(n) })
        }
      })
    "coords" =>
      scalar1(db, name, args, row, group, fn(v) {
        match as_int(v) {
          Err(message) => Failed(err_response("INVALID_INPUT", message))
          Ok(n) =>
            match coords_of(db.lattice, n) {
              Some(c) => Value(Text(format_coords(c)))
              None => Value(Null)
            }
        }
      })
    "digits" =>
      scalar1(db, name, args, row, group, fn(v) {
        match as_int(v) {
          Err(message) => Failed(err_response("INVALID_INPUT", message))
          Ok(n) =>
            match Tesseract::cell_at(db, n) {
              Some(cell) => Value(Int(cell.digit))
              None => Value(Null)
            }
        }
      })
    "line" | "slab" | "peers" => geometry_predicate(db, name, args, row)
    "json_extract" => json_extract_call(db, name, args, row, group)
    _ => Failed(err_response("INVALID_SYNTAX", "Unknown function: " + name))
  }
}

///|
/// A one-argument scalar, arity checked here so the message can say which.
fn scalar1(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  row : Record?,
  group : Array[Record],
  f : (SqlValue) -> Eval,
) -> Eval {
  if args.length() != 1 {
    return Failed(
      err_response("INVALID_SYNTAX", name + "() takes one argument"),
    )
  }
  match eval_value(db, args[0], row, group) {
    Failed(r) => Failed(r)
    Value(v) => f(v)
  }
}

///|
fn text1(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  row : Record?,
  group : Array[Record],
  f : (String) -> String,
) -> Eval {
  if args.length() != 1 {
    return Failed(
      err_response("INVALID_SYNTAX", name + "() takes one argument"),
    )
  }
  match eval_value(db, args[0], row, group) {
    Failed(r) => Failed(r)
    Value(Null) => Value(Null)
    Value(v) => Value(Text(f(render(v))))
  }
}

///|
/// `json_extract(text, path)` — the value at a path inside a JSON document.
///
/// The first argument is any text expression, so it composes: the `value`
/// column, a literal, or the result of another function. The second is the
/// path, `$.a.b[0].c`.
///
/// The two arguments are treated differently on purpose, and the reason is
/// where the mistake lives:
///
/// - A **malformed path** is an error, never an answer. The path is the same for
///   every row, so it is not the data's business whether it is well formed. It
///   is reported when the call is evaluated: against a probe row before any row
///   is read in a `WHERE`, and when the first row is evaluated in a select list
///   - the same rule the engine already applies to an unknown function and to a
///   wrong argument count.
/// - A **row** whose text is not JSON, or whose JSON has no such key, answers
///   `null`. One row holding a plain string must not take the whole query down
///   with it, and `null` is the answer SQL already has for "not known here".
///
/// The name matches SQLite's `json_extract` on purpose — the path syntax is the
/// same, so the function is familiar — but nothing of SQLite is underneath.
/// The parse is `moonbitlang/core/json`, which the package already depended on
/// for its own `.tsr` reader.
fn json_extract_call(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  row : Record?,
  group : Array[Record],
) -> Eval {
  if args.length() != 2 {
    return Failed(
      err_response("INVALID_SYNTAX", name + "() takes two arguments"),
    )
  }
  let path_text = match eval_value(db, args[1], row, group) {
    Failed(r) => return Failed(r)
    Value(v) => render(v)
  }
  let steps = match json_path_parse(path_text) {
    Err(message) => return Failed(err_response("INVALID_INPUT", message))
    Ok(s) => s
  }
  let outcome = match eval_value(db, args[0], row, group) {
    Failed(r) => Failed(r)
    Value(Null) => Value(Null)
    Value(v) => {
      let text = render(v)
      if !@json.valid(text) {
        return Value(Null)
      }
      // `preserve_number_repr` keeps the number exactly as it was written, so
      // an integer wider than a double survives without being rounded.
      let doc = @json.parse(text, preserve_number_repr=true) catch {
        _ => return Value(Null)
      }
      match json_walk(doc, steps) {
        Some(found) => Value(json_to_sql(found))
        None => Value(Null)
      }
    }
  }
  outcome
}

///|
/// `line(pos, axis)`, `slab(pos, axis)` and `peers(pos)` as predicates: does *this
/// row* lie in that set.
///
/// The old surface answered with the rows of the line and then filtered them by
/// the other predicates in the same `WHERE`, which is how `peers(1) AND
/// key='zzz'` once came back with a row. A per-row predicate cannot express that
/// mistake, because there is no separate row set to filter.
///
/// The axis check stays at the SQL boundary because `coord_at` used to fall
/// through to the last axis for anything out of range - `line(1,7)` answered
/// exactly what `line(1,3)` answers.
fn geometry_predicate(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  row : Record?,
) -> Eval {
  let r = match row {
    Some(v) => v
    None =>
      return Failed(
        err_response(
          "INVALID_COLUMNS",
          name + "() asks about the current row, and there is none",
        ),
      )
  }
  let wants_two = name == "line" || name == "slab"
  if args.length() != (if wants_two { 2 } else { 1 }) {
    return Failed(
      err_response(
        "INVALID_SYNTAX",
        name +
        "() takes " +
        (if wants_two { "two" } else { "one" }) +
        " arguments",
      ),
    )
  }
  let pos = match eval_value(db, args[0], Some(r), [r]) {
    Failed(err) => return Failed(err)
    Value(v) =>
      match as_int(v) {
        Err(message) => return Failed(err_response("INVALID_INPUT", message))
        Ok(n) => n
      }
  }
  let mut axis = 0L
  if wants_two {
    let a = match eval_value(db, args[1], Some(r), [r]) {
      Failed(err) => return Failed(err)
      Value(v) =>
        match as_int(v) {
          Err(message) => return Failed(err_response("INVALID_INPUT", message))
          Ok(n) => n
        }
    }
    if a < 0L || a >= DIM {
      return Failed(
        err_response(
          "INVALID_SYNTAX",
          "Axis must be 0.." + (DIM - 1L).to_string() + ", got " + a.to_string(),
        ),
      )
    }
    axis = a
  }
  let lat = db.lattice
  if !position_in_bounds(lat, pos) {
    return Failed(
      err_response(
        "POSITION_OUT_OF_RANGE",
        "Position out of range: " + pos.to_string(),
      ),
    )
  }
  let anchor = match coords_of(lat, pos) {
    Some(c) => c
    None =>
      return Failed(
        err_response(
          "POSITION_OUT_OF_RANGE",
          "Position out of range: " + pos.to_string(),
        ),
      )
  }
  let on = if name == "line" {
    same_except_one(r.coords, anchor, axis)
  } else if name == "slab" {
    coord_at_unchecked(r.coords, axis) == coord_at_unchecked(anchor, axis)
  } else {
    // Peers are the cells sharing a line with the given one, *not including it*.
    // `shares_line(c, c)` is trivially true - a cell agrees with itself on all but
    // any one axis - so without this guard `WHERE peers(1)` returned the row at
    // position 1 along with its eight line-mates, and a query naming a position
    // got that position's own record back.
    shares_line(r.coords, anchor) && r.position != pos
  }
  Value(bool_value(on))
}

///|
/// Two cells share the axis-parallel line along `axis` when they agree on every
/// other coordinate.
fn same_except_one(c : Coords, anchor : Coords, axis : Int64) -> Bool {
  let mut a = 0L
  while a < DIM {
    if a != axis && coord_at_unchecked(c, a) != coord_at_unchecked(anchor, a) {
      return false
    }
    a = a + 1L
  }
  true
}

///|
/// `count`, `sum`, `min`, `max`, `avg` over the group.
///
/// `count(*)` counts rows; `count(expr)` counts the rows where `expr` is not
/// unknown. `sum`, `avg`, `min` and `max` over nothing are unknown rather than
/// zero, because `sum` of no rows is not zero and reporting it as zero would let
/// `WHERE sum(digit) = 0` match an empty group.
fn aggregate(
  db : Tesseract,
  name : String,
  args : Array[Expr],
  group : Array[Record],
) -> Eval {
  if args.length() != 1 {
    return Failed(
      err_response("INVALID_SYNTAX", name + "() takes one argument"),
    )
  }
  let star = match args[0] {
    Star => true
    _ => false
  }
  let mut counted = 0L
  let mut sum = 0L
  let mut best : SqlValue = Null
  for row in group {
    if star {
      if name == "count" {
        counted = counted + 1L
      }
      continue
    }
    let v = match eval_value(db, args[0], Some(row), group) {
      Failed(r) => return Failed(r)
      Value(x) => x
    }
    if v == Null {
      continue
    }
    counted = counted + 1L
    let n = match as_int(v) {
      Err(message) => return Failed(err_response("INVALID_INPUT", message))
      Ok(x) => x
    }
    sum = sum + n
    best = if best == Null {
      v
    } else if name == "min" {
      if compare_values(v, best) < 0 {
        v
      } else {
        best
      }
    } else if compare_values(v, best) > 0 {
      v
    } else {
      best
    }
  }
  if name == "count" {
    Value(Int(counted))
  } else if name == "sum" {
    if counted == 0L {
      Value(Null)
    } else {
      Value(Int(sum))
    }
  } else if name == "avg" {
    if counted == 0L {
      Value(Null)
    } else {
      Value(Int(sum / counted))
    }
  } else {
    Value(best)
  }
}

// ---------------------------------------------------------------------------
// INSERT / UPDATE / DELETE
// ---------------------------------------------------------------------------

///|
/// The position an `AT` clause names, or the cursor when it names nothing.
fn resolve_target(
  db : Tesseract,
  target : Target,
) -> Result[Int64?, DBResponse] {
  let lat = db.lattice
  match target {
    None => Ok(None)
    Position(p) =>
      if !position_in_bounds(lat, p) {
        Err(
          err_response(
            "INVALID_POSITION",
            "Position out of range: " +
            p.to_string() +
            " (1.." +
            lat.total.to_string() +
            ")",
          ),
        )
      } else {
        Ok(Some(p))
      }
    Coords(c) => {
      if c.length() != DIM.to_int() {
        return Err(
          err_response("INVALID_SYNTAX", "A 4D address needs four coordinates"),
        )
      }
      let made = coords(c[0], c[1], c[2], c[3])
      // Out of range is refused by coordinate, naming the coordinate - never
      // clamped. A clamp would write to a cell nobody asked for, which is the one
      // failure mode this project has refused everywhere else.
      if !coords_in_bounds(lat, made) {
        return Err(
          err_response(
            "INVALID_POSITION",
            "Coordinate " +
            format_coords(made) +
            " is outside a " +
            lat.side.to_string() +
            "-per-axis lattice",
          ),
        )
      }
      Ok(Some(position_of(lat, made)))
    }
  }
}

///|
/// `INSERT INTO tesseract (...) VALUES (...) [AT ...]`.
fn run_insert(
  db : Tesseract,
  cols : Array[String],
  values : Array[Expr],
  target : Target,
) -> DBResponse {
  if cols.length() != values.length() {
    return err_response(
      "INVALID_COLUMNS",
      "INSERT names " +
      cols.length().to_string() +
      " columns and gives " +
      values.length().to_string() +
      " values",
    )
  }
  let mut position = match resolve_target(db, target) {
    Ok(p) => p
    Err(r) => return r
  }
  let mut stamp = ""
  let mut key = ""
  let mut value = ""
  let mut digit = 0L
  let mut i = 0
  while i < cols.length() {
    let name = lower(cols[i])
    let v = match eval_value(db, values[i], None, []) {
      Failed(r) => return r
      Value(x) => x
    }
    if name == "key" {
      key = render(v)
    } else if name == "value" {
      value = render(v)
    } else if name == "digit" {
      match as_int(v) {
        Ok(n) => digit = n
        Err(message) => return err_response("INVALID_INPUT", message)
      }
    } else if name == "grid_position" || name == "position" {
      // The C# dialect addressed a row by a column rather than by `AT`, and its
      // dumps are documented as still loading. An explicit `AT` wins, because a
      // statement that says where it is going in two places is better off with one
      // answer than with an error over which of them is read first.
      if position is None {
        match as_int(v) {
          Ok(n) =>
            if !position_in_bounds(db.lattice, n) {
              return err_response(
                "INVALID_POSITION",
                "Position out of range: " + n.to_string(),
              )
            } else {
              position = Some(n)
            }
          Err(message) => return err_response("INVALID_INPUT", message)
        }
      }
    } else if name == "timestamp" {
      // Carried into the cell rather than dropped, which is what makes a `.sql`
      // round trip keep its stamps. `insert_stamped` is the same call the `.tsr`
      // and `.db` importers use.
      stamp = render(v)
    } else {
      return err_response(
        "INVALID_COLUMNS",
        "INSERT takes key, value, digit, grid_position and timestamp; got column " +
        name,
      )
    }
    i = i + 1
  }
  Tesseract::insert_stamped(
    db,
    key,
    value,
    position,
    digit,
    if stamp == "" {
      None
    } else {
      Some(stamp)
    },
  )
}

///|
/// `UPDATE tesseract SET ... [WHERE ...]`.
///
/// Rows are updated one at a time and the first refusal ends the statement. The
/// rows already written are undone by the implicit statement savepoint in
/// `execute`, which is the whole reason that savepoint is opened for every
/// statement rather than only inside a `BEGIN`.
fn run_update(
  db : Tesseract,
  sets : Array[Assignment],
  filter : Expr?,
) -> DBResponse {
  // The SET list is checked against a row that does not exist before the scan,
  // for the same reason the filter is: `UPDATE ... SET bogus = 'x'` on an empty
  // table matched nothing, so `bogus` was never evaluated and the statement
  // succeeded. Which columns exist is not a fact about the data.
  let probe = probe_row(db)
  let mut i = 0
  while i < sets.length() {
    let name = lower(sets[i].column)
    if name != "value" && name != "digit" && name != "key" {
      return err_response(
        "INVALID_COLUMNS",
        "UPDATE SET takes value and digit; got column " + name,
      )
    }
    match eval_value(db, sets[i].value, Some(probe), [probe]) {
      Failed(r) => return r
      Value(_) => ()
    }
    i = i + 1
  }
  let (rows, failure) = filter_rows(db, all_rows(db), filter)
  if failure is Some(_) {
    let f = failure.unwrap()
    return f
  }
  let mut affected = 0L
  for row in rows {
    let mut value = row.value
    let mut digit = row.digit
    let mut named_digit = false
    let mut i = 0
    while i < sets.length() {
      let name = lower(sets[i].column)
      let v = match eval_value(db, sets[i].value, Some(row), [row]) {
        Failed(r) => return r
        Value(x) => x
      }
      if name == "value" {
        value = render(v)
      } else if name == "digit" {
        match as_int(v) {
          Err(message) => return err_response("INVALID_INPUT", message)
          Ok(n) => {
            digit = n
            named_digit = true
          }
        }
      } else if name == "key" {
        return err_response(
          "INVALID_COLUMNS", "UPDATE SET takes value and digit; the key names the record",
        )
      } else {
        return err_response(
          "INVALID_COLUMNS",
          "UPDATE SET takes value and digit; got column " + name,
        )
      }
      i = i + 1
    }
    let result = Tesseract::update(
      db,
      row.key,
      value,
      Some(row.position),
      if named_digit {
        Some(digit)
      } else {
        None
      },
    )
    if !result.success {
      return result
    }
    affected = affected + 1L
  }
  let base = ok_response("UPDATE")
  {
    success: base.success,
    operation: "UPDATE",
    affected_rows: affected,
    position: 0L,
    error: base.error,
    error_code: base.error_code,
    message: base.message,
    data: [],
    total_records: affected,
  }
}

///|
/// `DELETE FROM tesseract [WHERE ...]`.
fn run_delete(db : Tesseract, filter : Expr?) -> DBResponse {
  let (rows, failure) = filter_rows(db, all_rows(db), filter)
  if failure is Some(_) {
    let f = failure.unwrap()
    return f
  }
  let mut affected = 0L
  for row in rows {
    let result = Tesseract::delete(db, row.key, Some(row.position))
    if !result.success {
      return result
    }
    affected = affected + 1L
  }
  let base = ok_response("DELETE")
  {
    success: base.success,
    operation: "DELETE",
    affected_rows: affected,
    position: 0L,
    error: base.error,
    error_code: base.error_code,
    message: base.message,
    data: [],
    total_records: affected,
  }
}

// ---------------------------------------------------------------------------
// SELECT
// ---------------------------------------------------------------------------

///|
/// A label for a select-list item that is not a bare column.
///
/// The label is what a `Computed` cell is filed under, so it has to be the thing
/// the user wrote: `count(*)` rather than a generated name, because a result a
/// caller has to label by position is a result they cannot read.
fn label_of(e : Expr) -> String {
  match e {
    Literal(v) => render(v)
    Star => "*"
    Column(name) => name
    Neg(inner) => "-" + label_of(inner)
    Not(inner) => "NOT " + label_of(inner)
    Binary(op, a, b) => "(" + label_of(a) + " " + op + " " + label_of(b) + ")"
    Like(a, b) => label_of(a) + " LIKE " + label_of(b)
    In(a, list) => {
      let b = StringBuilder::StringBuilder()
      b.write_string(label_of(a))
      b.write_string(" IN (")
      let mut i = 0
      while i < list.length() {
        if i > 0 {
          b.write_string(", ")
        }
        b.write_string(label_of(list[i]))
        i = i + 1
      }
      b.write_string(")")
      b.to_string()
    }
    IsNull(a, negated) =>
      label_of(a) + (if negated { " IS NOT NULL" } else { " IS NULL" })
    Call(name, args) => {
      let b = StringBuilder::StringBuilder()
      b.write_string(name)
      b.write_string("(")
      let mut i = 0
      while i < args.length() {
        if i > 0 {
          b.write_string(", ")
        }
        b.write_string(label_of(args[i]))
        i = i + 1
      }
      b.write_string(")")
      b.to_string()
    }
  }
}

///|
/// True when the expression tree contains an aggregate call.
fn has_aggregate(e : Expr) -> Bool {
  match e {
    Call(name, args) =>
      if is_aggregate(name) {
        true
      } else {
        let mut found = false
        for a in args {
          if has_aggregate(a) {
            found = true
          }
        }
        found
      }
    Binary(_, a, b) => has_aggregate(a) || has_aggregate(b)
    Neg(a) | Not(a) | IsNull(a, _) => has_aggregate(a)
    Like(a, b) => has_aggregate(a) || has_aggregate(b)
    In(a, list) => {
      if has_aggregate(a) {
        return true
      }
      for item in list {
        if has_aggregate(item) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// True when the expression is a plain column reference.
fn plain_column(e : Expr) -> String? {
  match e {
    Column(name) => Some(lower(name))
    _ => None
  }
}

///|
/// A row with only the named columns filled in, everything else emptied.
///
/// `Record` is a fixed shape, so a narrower select is an emptied row rather than a
/// narrower one. That is lossy on purpose and visible: a caller that asked for
/// `key` gets empty `value` and `digit`, not stale copies of them.
///
/// `position` and `coords` are emptied the same way, and that is what makes
/// `DISTINCT` mean what it says. Carrying the source position through a
/// projection leaves every row distinguishable no matter which columns were asked
/// for, so `SELECT DISTINCT value` over three cells holding one value returned
/// three rows. A caller that wants the cell back asks for `position`.
fn project(row : Record, wanted : Array[String]) -> Record {
  {
    key: if wanted.contains("key") {
      row.key
    } else {
      ""
    },
    value: if wanted.contains("value") {
      row.value
    } else {
      ""
    },
    position: if wanted.contains("position") || wanted.contains("grid_position") {
      row.position
    } else {
      0L
    },
    coords: if wanted.contains("x") ||
      wanted.contains("y") ||
      wanted.contains("z") ||
      wanted.contains("w") {
      row.coords
    } else {
      coords(0L, 0L, 0L, 0L)
    },
    timestamp: if wanted.contains("timestamp") {
      row.timestamp
    } else {
      ""
    },
    digit: if wanted.contains("digit") {
      row.digit
    } else {
      NO_DIGIT
    },
    computed: [],
  }
}

///|
/// `SELECT [DISTINCT] ... [WHERE] [GROUP BY] [ORDER BY] [LIMIT] [OFFSET]`.
fn run_select(db : Tesseract, spec : SelectSpec) -> DBResponse {
  let (kept, failure) = filter_rows(db, all_rows(db), spec.filter)
  if failure is Some(_) {
    let f = failure.unwrap()
    return f
  }
  // Before the grouping decision, because it is the grouped path that has no
  // failure channel: `group_key` returns a `String` and `order_rows` returns an
  // `Array[Record]`, so neither can report that the column was unknown. Refusing
  // it here is the only place the answer can still be an error.
  let column_failure = validate_select_columns(db, spec)
  if column_failure is Some(_) {
    let cf = column_failure.unwrap()
    return cf
  }
  // An aggregate anywhere in the select list, or a GROUP BY, makes this a grouped
  // query: one output row per group instead of one per stored row.
  let mut grouped = spec.group_by.length() > 0
  if !grouped {
    for c in spec.columns {
      if has_aggregate(c) {
        grouped = true
      }
    }
  }
  let mut out : Array[Record] = []
  if grouped {
    let (rows, failure) = group_rows(db, kept, spec)
    if failure is Some(_) {
      let f = failure.unwrap()
      return f
    }
    out = rows
  } else {
    // ORDER BY runs before DISTINCT and LIMIT, which is the order the clause
    // keywords are written in. Applying it last would mean `LIMIT 3` picking
    // three rows that then had to be sorted - a different answer to the question.
    // The clause order is the keyword order. The one thing worth spelling out is
    // that the projection runs *before* `DISTINCT`: de-duplicating whole records
    // would never collapse two rows that agree in the selected columns and differ
    // only in a column nobody asked for, which is the whole point of
    // `SELECT DISTINCT value` over three cells holding the same value.
    let sorted = order_rows(db, kept, spec.order_by)
    let (projected, project_failure) = apply_columns(db, sorted, spec)
    if project_failure is Some(_) {
      let pf = project_failure.unwrap()
      return pf
    }
    let deduped = if spec.distinct {
      distinct_rows(projected)
    } else {
      projected
    }
    let sliced = slice_rows(db, deduped, spec.limit, spec.offset)
    out = sliced
  }
  let base = ok_response("SELECT")
  {
    success: base.success,
    operation: "SELECT",
    affected_rows: out.length().to_int64(),
    position: 0L,
    error: base.error,
    error_code: base.error_code,
    message: base.message,
    data: out,
    total_records: out.length().to_int64(),
  }
}

///|
/// Groups the rows and evaluates the select list once per group.
fn group_rows(
  db : Tesseract,
  rows : Array[Record],
  spec : SelectSpec,
) -> (Array[Record], DBResponse?) {
  // Group keys are rendered to text so they can be compared and kept in an array
  // without needing a hashable key type. The lattice is one table, so the group
  // count is bounded by the occupied cells and a linear scan is not the bottleneck.
  let keys : Array[String] = []
  let members : Array[Array[Record]] = []
  for row in rows {
    let key = group_key(db, row, spec.group_by)
    let mut found = -1
    let mut i = 0
    while i < keys.length() {
      if keys[i] == key {
        found = i
      }
      i = i + 1
    }
    if found < 0 {
      keys.push(key)
      members.push([row])
    } else {
      members[found].push(row)
    }
  }
  let out : Array[Record] = []
  let mut g = 0
  while g < keys.length() {
    let group = members[g]
    let head = group[0]
    let computed : Array[Computed] = []
    if !spec.star {
      for c in spec.columns {
        match plain_column(c) {
          Some(_) => ()
          None =>
            match eval_value(db, c, Some(head), group) {
              Failed(r) => return ([], Some(r))
              Value(v) =>
                computed.push(Computed::{
                  label: label_of(c),
                  value: render(v),
                })
            }
        }
      }
    }
    let wanted : Array[String] = []
    if spec.star {
      let all = [
        "key", "value", "position", "digit", "timestamp", "x", "y", "z", "w",
      ]
      for c in all {
        wanted.push(c)
      }
    } else {
      for c in spec.columns {
        match plain_column(c) {
          Some(name) => wanted.push(name)
          None => ()
        }
      }
    }
    let base = project(head, wanted)
    out.push({
      key: base.key,
      value: base.value,
      position: base.position,
      coords: base.coords,
      timestamp: base.timestamp,
      digit: base.digit,
      computed,
    })
    g = g + 1
  }
  (out, None)
}

///|
/// The text key a row groups under.
fn group_key(db : Tesseract, row : Record, terms : Array[Expr]) -> String {
  if terms.length() == 0 {
    return "*"
  }
  let b = StringBuilder::StringBuilder()
  let mut i = 0
  while i < terms.length() {
    if i > 0 {
      b.write_string(" | ")
    }
    match eval_value(db, terms[i], Some(row), [row]) {
      Failed(r) => b.write_string("!" + r.error_code)
      Value(v) => b.write_string(render(v))
    }
    i = i + 1
  }
  b.to_string()
}

///|
/// Applies the select list to rows that are not grouped.
///
/// Plain columns narrow the row; anything else in the list is evaluated and
/// attached as a `computed` entry under the label it was written with. The
/// earlier version kept only the plain columns and quietly dropped the rest, so
/// `SELECT length(key) FROM tesseract` returned a row whose `value` was the
/// underlying record's value and said nothing at all about the function - the
/// same "accept the clause, then mean something else by it" failure the engine
/// was written to remove, this time in the executor rather than the parser.
fn apply_columns(
  db : Tesseract,
  rows : Array[Record],
  spec : SelectSpec,
) -> (Array[Record], DBResponse?) {
  if spec.star && spec.columns.length() == 0 {
    return (rows, None)
  }
  let wanted : Array[String] = []
  let derived : Array[Expr] = []
  for c in spec.columns {
    match plain_column(c) {
      Some(name) => wanted.push(name)
      None => derived.push(c)
    }
  }
  if wanted.length() == 0 && derived.length() == 0 {
    return (rows, None)
  }
  let out : Array[Record] = []
  for row in rows {
    let computed : Array[Computed] = []
    for e in derived {
      match eval_value(db, e, Some(row), [row]) {
        Failed(r) => return ([], Some(r))
        Value(v) =>
          computed.push(Computed::{ label: label_of(e), value: render(v), })
      }
    }
    let base = project(row, wanted)
    out.push({
      key: base.key,
      value: base.value,
      position: base.position,
      coords: base.coords,
      timestamp: base.timestamp,
      digit: base.digit,
      computed,
    })
  }
  (out, None)
}

///|
/// Sorts rows by the `ORDER BY` terms, stably.
///
/// Stability is why this is hand-rolled rather than borrowed. `ORDER BY digit`
/// over rows whose digits tie has to leave them in position order, or `LIMIT`
/// picks an arbitrary subset and two runs of the same query disagree. Every tie
/// is broken by original index, which makes the order *total* - so the merge has
/// nothing to remember about which run a row came from, and the sort is stable by
/// construction rather than by discipline.
///
/// Sorting indices and mapping back at the end, rather than moving rows, is what
/// keeps the keys from being permuted separately from the rows they belong to.
fn order_rows(
  db : Tesseract,
  rows : Array[Record],
  terms : Array[OrderTerm],
) -> Array[Record] {
  if terms.length() == 0 || rows.length() < 2 {
    return rows
  }
  let keys : Array[Array[SqlValue]] = []
  for row in rows {
    let line : Array[SqlValue] = []
    for t in terms {
      match eval_value(db, t.expr, Some(row), [row]) {
        Failed(_) => line.push(Null)
        Value(v) => line.push(v)
      }
    }
    keys.push(line)
  }
  let indices : Array[Int32] = []
  let mut i = 0
  while i < rows.length() {
    indices.push(i)
    i = i + 1
  }
  let sorted = sort_indices(indices, keys, terms, 0, rows.length())
  let out : Array[Record] = []
  for at in sorted {
    out.push(rows[at])
  }
  out
}

///|
/// Bottom-up merge sort over indices.
fn sort_indices(
  idx : Array[Int32],
  keys : Array[Array[SqlValue]],
  terms : Array[OrderTerm],
  lo : Int32,
  hi : Int32,
) -> Array[Int32] {
  if hi - lo < 2 {
    let whole : Array[Int32] = []
    let mut k = lo
    while k < hi && k < idx.length() {
      whole.push(idx[k])
      k = k + 1
    }
    return whole
  }
  let mid = lo + (hi - lo) / 2
  let left = sort_indices(idx, keys, terms, lo, mid)
  let right = sort_indices(idx, keys, terms, mid, hi)
  merge_indices(left, right, keys, terms)
}

///|
/// Merges two sorted index runs, taking from the left on a tie.
fn merge_indices(
  left : Array[Int32],
  right : Array[Int32],
  keys : Array[Array[SqlValue]],
  terms : Array[OrderTerm],
) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    if index_before(left[i], right[j], keys, terms) {
      out.push(left[i])
      i = i + 1
    } else {
      out.push(right[j])
      j = j + 1
    }
  }
  while i < left.length() {
    out.push(left[i])
    i = i + 1
  }
  while j < right.length() {
    out.push(right[j])
    j = j + 1
  }
  out
}

///|
/// True when row `a` sorts before row `b`.
///
/// Unknown sorts before every known value, in both directions - it is not a
/// number and putting it at an end that depends on `DESC` would make the answer
/// depend on the direction. The original index is the final tie-break, so this
/// comparison is a strict total order and the sort above is stable.
fn index_before(
  a : Int32,
  b : Int32,
  keys : Array[Array[SqlValue]],
  terms : Array[OrderTerm],
) -> Bool {
  let mut t = 0
  while t < terms.length() {
    let x = keys[a][t]
    let y = keys[b][t]
    let c = if x == Null && y == Null {
      0
    } else if x == Null {
      -1
    } else if y == Null {
      1
    } else {
      compare_values(x, y)
    }
    if c != 0 {
      return if terms[t].descending { c > 0 } else { c < 0 }
    }
    t = t + 1
  }
  a < b
}

///|
/// A half-open slice of an array.
fn slice_array(rows : Array[Record], from : Int32, to : Int32) -> Array[Record] {
  let out : Array[Record] = []
  let mut i = from
  while i < to && i < rows.length() {
    out.push(rows[i])
    i = i + 1
  }
  out
}

///|
/// Drops rows that repeat, keeping the first of each run.
fn distinct_rows(rows : Array[Record]) -> Array[Record] {
  let out : Array[Record] = []
  for row in rows {
    let mut seen = false
    for kept in out {
      if same_record(kept, row) {
        seen = true
      }
    }
    if !seen {
      out.push(row)
    }
  }
  out
}

///|
fn same_record(a : Record, b : Record) -> Bool {
  a.key == b.key &&
  a.value == b.value &&
  a.position == b.position &&
  a.digit == b.digit &&
  a.timestamp == b.timestamp
}

///|
/// `LIMIT` and `OFFSET`, in that order, over an already-sorted list.
fn slice_rows(
  db : Tesseract,
  rows : Array[Record],
  limit : Expr?,
  offset : Expr?,
) -> Array[Record] {
  let mut start = 0
  let mut count = rows.length()
  match offset {
    None => ()
    Some(e) =>
      match eval_value(db, e, None, []) {
        Failed(_) => ()
        Value(v) =>
          match as_int(v) {
            Err(_) => ()
            Ok(n) =>
              if n < 0L {
                start = 0
              } else if n > rows.length().to_int64() {
                start = rows.length()
              } else {
                start = n.to_int()
              }
          }
      }
  }
  match limit {
    None => ()
    Some(e) =>
      match eval_value(db, e, None, []) {
        Failed(_) => ()
        Value(v) =>
          match as_int(v) {
            Err(_) => ()
            Ok(n) => {
              let room = rows.length() - start
              if n < 0L {
                count = 0
              } else if n > room.to_int64() {
                count = room
              } else {
                count = n.to_int()
              }
            }
          }
      }
  }
  slice_array(rows, start, start + count)
}
