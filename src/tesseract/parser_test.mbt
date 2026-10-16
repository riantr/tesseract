///|
/// The SQL parser: the clauses the old scanner dropped, the precedence it did
/// not have, and the errors it answered instead of naming.
///
/// Each test below pins a behaviour that was measured wrong against the real
/// CLI before this layer existed. The comments say what was broken, because a
/// test that only records the right answer does not tell the next reader why
/// the assertion is there - and several of these look like trivia until you
/// know what they used to return.
///
/// Assertions are written as matches rather than as equality against a built
/// value: this toolchain will not let a blackbox test *construct* a package
/// enum, and matching one is allowed. The expected shape is in the pattern, so
/// a tree that came back different falls to the `abort` arm with a message
/// naming what was wanted.

///|
/// The statement `sql` parses to.
fn parsed(sql : String) -> @tesseract.Stmt {
  match @tesseract.parse_statement(sql) {
    Ok(s) => s
    Err(e) => abort("expected a parse: " + e.message)
  }
}

///|
/// The failure of a statement that does not parse.
fn parse_failure(sql : String) -> @tesseract.ParseError {
  match @tesseract.parse_statement(sql) {
    Ok(_) => abort("expected a parse failure from: " + sql)
    Err(e) => e
  }
}

///|
/// The `SelectSpec` of a statement.
fn spec_of(sql : String) -> @tesseract.SelectSpec {
  match parsed(sql) {
    Select(s) => s
    _ => abort("expected a SELECT from: " + sql)
  }
}

///|
/// The `WHERE` expression of a statement, or `abort`.
fn filter_of(sql : String) -> @tesseract.Expr {
  match spec_of(sql).filter {
    Some(e) => e
    None => abort("expected a WHERE clause in: " + sql)
  }
}

///|
/// True when `e` is `column op 'text'`.
fn is_text_cmp(
  e : @tesseract.Expr,
  op : String,
  column : String,
  text : String,
) -> Bool {
  match e {
    Binary(o, Column(c), Literal(Text(v))) =>
      o == op && c == column && v == text
    _ => false
  }
}

///|
/// True when `e` is `column op n`.
fn is_int_cmp(
  e : @tesseract.Expr,
  op : String,
  column : String,
  n : Int64,
) -> Bool {
  match e {
    Binary(o, Column(c), Literal(Int(v))) => o == op && c == column && v == n
    _ => false
  }
}

///|
/// True when `e` is the integer literal `n`.
fn is_int(e : @tesseract.Expr, n : Int64) -> Bool {
  match e {
    Literal(Int(v)) => v == n
    _ => false
  }
}

///|
/// True when `e` is the column `name`.
fn is_column(e : @tesseract.Expr, name : String) -> Bool {
  match e {
    Column(c) => c == name
    _ => false
  }
}

///|
/// True when `e` is `a + b` of two integer literals.
fn is_int_add(e : @tesseract.Expr, a : Int64, b : Int64) -> Bool {
  match e {
    Binary("+", l, r) => is_int(l, a) && is_int(r, b)
    _ => false
  }
}

///|
/// True when `e` is `a * b` of two integer literals.
fn is_int_mul(e : @tesseract.Expr, a : Int64, b : Int64) -> Bool {
  match e {
    Binary("*", l, r) => is_int(l, a) && is_int(r, b)
    _ => false
  }
}

///|
test "two conjuncts on one column nest instead of overwriting each other" {
  // The measured case: `WHERE key='alpha' AND key='beta'` answered with the
  // beta row, because the old `Where` held one predicate per field and the
  // second conjunct replaced the first. A nested tree is the only shape in
  // which both survive.
  let f = filter_of(
    "SELECT * FROM tesseract WHERE key = 'alpha' AND key = 'beta'",
  )
  match f {
    Binary("AND", left, right) => {
      assert_true(is_text_cmp(left, "=", "key", "alpha"))
      assert_true(is_text_cmp(right, "=", "key", "beta"))
    }
    _ => abort("expected an AND of two comparisons on the same column")
  }
  // Three conjuncts keep all three. `AND` is left-associative, so the tree
  // groups to the left: `(a AND b) AND c`.
  let three = filter_of(
    "SELECT * FROM tesseract WHERE key = 'a' AND key = 'b' AND key = 'c'",
  )
  match three {
    Binary("AND", l, r) => {
      assert_true(is_text_cmp(r, "=", "key", "c"))
      match l {
        Binary("AND", ll, lr) => {
          assert_true(is_text_cmp(ll, "=", "key", "a"))
          assert_true(is_text_cmp(lr, "=", "key", "b"))
        }
        _ => abort("expected the left side of the AND chain to be an AND too")
      }
    }
    _ => abort("expected an AND chain")
  }
}

///|
test "OR parses, and nests inside AND where parentheses put it" {
  // `WHERE key = 'alpha' OR key = 'beta'` was INVALID_SYNTAX: the old layer
  // split a WHERE on AND and had nowhere to put a disjunction.
  let one = filter_of(
    "SELECT * FROM tesseract WHERE key = 'alpha' OR key = 'beta'",
  )
  match one {
    Binary("OR", left, right) => {
      assert_true(is_text_cmp(left, "=", "key", "alpha"))
      assert_true(is_text_cmp(right, "=", "key", "beta"))
    }
    _ => abort("expected an OR of two comparisons")
  }
  // `AND` binds tighter than `OR` without parentheses.
  let loose = filter_of(
    "SELECT * FROM tesseract WHERE x = 1 AND y = 2 OR z = 3",
  )
  match loose {
    Binary("OR", left, right) => {
      assert_true(
        match left {
          Binary("AND", a, b) =>
            is_int_cmp(a, "=", "x", 1L) && is_int_cmp(b, "=", "y", 2L)
          _ => false
        },
      )
      assert_true(is_int_cmp(right, "=", "z", 3L))
    }
    _ => abort("expected the disjunction at the top")
  }
  // ...and an explicit group is the same tree.
  let grouped = filter_of(
    "SELECT * FROM tesseract WHERE x = 1 AND (y = 2 OR z = 3)",
  )
  match grouped {
    Binary("AND", left, right) => {
      assert_true(is_int_cmp(left, "=", "x", 1L))
      match right {
        Binary("OR", a, b) => {
          assert_true(is_int_cmp(a, "=", "y", 2L))
          assert_true(is_int_cmp(b, "=", "z", 3L))
        }
        _ => abort("expected the parenthesised disjunction")
      }
    }
    _ => abort("expected the conjunction at the top")
  }
}

///|
test "LIMIT and OFFSET land in the spec instead of being dropped" {
  // `LIMIT 1` returned all three rows, which reads as a statement about the
  // data rather than a clause that was ignored.
  let s = spec_of("SELECT * FROM tesseract LIMIT 1")
  assert_true(s.star)
  match s.limit {
    Some(e) => assert_true(is_int(e, 1L))
    None => abort("LIMIT 1 was dropped")
  }
  assert_true(s.offset == None)
  let both = spec_of("SELECT * FROM tesseract LIMIT 2 OFFSET 5")
  match both.limit {
    Some(e) => assert_true(is_int(e, 2L))
    None => abort("LIMIT 2 was dropped")
  }
  match both.offset {
    Some(e) => assert_true(is_int(e, 5L))
    None => abort("OFFSET 5 was dropped")
  }
  // A clause that is present and evaluates to nothing is not a missing clause.
  // `LIMIT 0` has to be Some, or the executor cannot tell it from `LIMIT`.
  match spec_of("SELECT * FROM tesseract LIMIT 0").limit {
    Some(e) => assert_true(is_int(e, 0L))
    None => abort("LIMIT 0 was dropped")
  }
  // The limit is an expression, not just a number.
  match spec_of("SELECT * FROM tesseract LIMIT 1 + 1").limit {
    Some(e) => assert_true(is_int_add(e, 1L, 1L))
    None => abort("LIMIT 1 + 1 was dropped")
  }
}

///|
test "ORDER BY keeps its terms and their direction" {
  // `ORDER BY key DESC` used to return insertion order with no error, so a
  // client could not tell a sorted answer from an unsorted one.
  let desc = spec_of("SELECT * FROM tesseract ORDER BY key DESC")
  assert_eq(desc.order_by.length(), 1)
  assert_true(is_column(desc.order_by[0].expr, "key"))
  assert_true(desc.order_by[0].descending)
  // `ASC` and no direction are the same term, so the executor has one comparison.
  assert_false(
    spec_of("SELECT * FROM tesseract ORDER BY key ASC").order_by[0].descending,
  )
  assert_false(
    spec_of("SELECT * FROM tesseract ORDER BY key").order_by[0].descending,
  )
  let two = spec_of("SELECT * FROM tesseract ORDER BY digit DESC, key ASC")
  assert_eq(two.order_by.length(), 2)
  assert_true(is_column(two.order_by[0].expr, "digit"))
  assert_true(two.order_by[0].descending)
  assert_true(is_column(two.order_by[1].expr, "key"))
  assert_false(two.order_by[1].descending)
}

///|
test "arithmetic binds tighter than addition and reaches the WHERE clause" {
  // `WHERE digit = 1 + 1` was INVALID_SYNTAX: the old parser had no
  // arithmetic at all, so a statement the grammar allows could not be written.
  let one = filter_of("SELECT * FROM tesseract WHERE digit = 1 + 1")
  match one {
    Binary("=", Column(c), rhs) => {
      assert_eq(c, "digit")
      assert_true(is_int_add(rhs, 1L, 1L))
    }
    _ => abort("expected digit = 1 + 1")
  }
  // `*` binds tighter than `+`, so this is `(2*3) + 4` and not `2 * (3+4)`.
  let tight = filter_of("SELECT * FROM tesseract WHERE digit = 2 * 3 + 4")
  match tight {
    Binary("=", Column(c), rhs) => {
      assert_eq(c, "digit")
      match rhs {
        Binary("+", l, r) => {
          assert_true(is_int_mul(l, 2L, 3L))
          assert_true(is_int(r, 4L))
        }
        _ => abort("expected (2*3) + 4")
      }
    }
    _ => abort("expected digit = 2 * 3 + 4")
  }
  // Parentheses override it.
  let loose = filter_of("SELECT * FROM tesseract WHERE digit = 2 * (3 + 4)")
  match loose {
    Binary("=", _, rhs) =>
      match rhs {
        Binary("*", l, r) => {
          assert_true(is_int(l, 2L))
          assert_true(is_int_add(r, 3L, 4L))
        }
        _ => abort("expected 2 * (3 + 4)")
      }
    _ => abort("expected a comparison")
  }
  // A unary minus is a node of its own.
  let neg = filter_of("SELECT * FROM tesseract WHERE digit = -1")
  match neg {
    Binary("=", Column(c), rhs) => {
      assert_eq(c, "digit")
      match rhs {
        Neg(inner) => assert_true(is_int(inner, 1L))
        _ => abort("expected a negation")
      }
    }
    _ => abort("expected digit = -1")
  }
}

///|
test "an operator inside a quoted literal does not split the condition" {
  // The exact bug the old parser had: it searched the raw text for the first
  // `=`, so this cut at the `=` inside the literal and the statement fell apart.
  assert_true(
    is_text_cmp(
      filter_of("SELECT * FROM tesseract WHERE key = 'x=y'"),
      "=",
      "key",
      "x=y",
    ),
  )
  // ...and the same for a keyword inside a literal.
  assert_true(
    is_text_cmp(
      filter_of("SELECT * FROM tesseract WHERE key = 'WHERE x = 1'"),
      "=",
      "key",
      "WHERE x = 1",
    ),
  )
}

///|
test "NOT binds tighter than AND and looser than comparison" {
  let s = filter_of("SELECT * FROM tesseract WHERE NOT x = 1 AND y = 2")
  match s {
    Binary("AND", left, right) => {
      match left {
        Not(inner) => assert_true(is_int_cmp(inner, "=", "x", 1L))
        _ => abort("expected the negation to take the comparison")
      }
      assert_true(is_int_cmp(right, "=", "y", 2L))
    }
    _ => abort("expected the conjunction at the top")
  }
  let grouped = filter_of("SELECT * FROM tesseract WHERE NOT (x = 1 AND y = 2)")
  match grouped {
    Not(inner) =>
      match inner {
        Binary("AND", a, b) => {
          assert_true(is_int_cmp(a, "=", "x", 1L))
          assert_true(is_int_cmp(b, "=", "y", 2L))
        }
        _ => abort("expected the conjunction inside the NOT")
      }
    _ => abort("expected a NOT")
  }
}

///|
test "the comparison operators are distinct nodes, and != folds to <>" {
  // Two spellings of not-equal reaching the executor would mean an executor
  // that matches on the operator string has to handle both.
  assert_true(
    is_text_cmp(
      filter_of("SELECT * FROM tesseract WHERE key != 'a'"),
      "<>",
      "key",
      "a",
    ),
  )
  assert_true(
    is_int_cmp(
      filter_of("SELECT * FROM tesseract WHERE digit <= 3"),
      "<=",
      "digit",
      3L,
    ),
  )
  assert_true(
    is_int_cmp(
      filter_of("SELECT * FROM tesseract WHERE digit > 3"),
      ">",
      "digit",
      3L,
    ),
  )
  assert_true(
    is_int_cmp(
      filter_of("SELECT * FROM tesseract WHERE digit < 3"),
      "<",
      "digit",
      3L,
    ),
  )
  assert_true(
    is_int_cmp(
      filter_of("SELECT * FROM tesseract WHERE digit >= 3"),
      ">=",
      "digit",
      3L,
    ),
  )
  assert_true(
    is_int_cmp(
      filter_of("SELECT * FROM tesseract WHERE digit = 3"),
      "=",
      "digit",
      3L,
    ),
  )
  // The other arithmetic operators are distinct too. `%` is multiplicative, so
  // it binds tighter than the comparison: this is `digit % 2 = 0`, not
  // `digit % (2 = 0)`.
  assert_true(
    match filter_of("SELECT * FROM tesseract WHERE digit % 2 = 0") {
      Binary("=", Binary("%", _, _), _) => true
      _ => false
    },
  )
  assert_true(
    match filter_of("SELECT * FROM tesseract WHERE digit / 2 - 1 = 0") {
      Binary("=", Binary("-", Binary("/", _, _), _), _) => true
      _ => false
    },
  )
}

///|
test "LIKE, IN and IS NULL build their own nodes" {
  match filter_of("SELECT * FROM tesseract WHERE value LIKE '%pat%'") {
    Like(Column(c), Literal(Text(v))) => {
      assert_eq(c, "value")
      assert_eq(v, "%pat%")
    }
    _ => abort("expected a LIKE")
  }
  match filter_of("SELECT * FROM tesseract WHERE digit IN (1, 2, 3)") {
    In(Column(c), items) => {
      assert_eq(c, "digit")
      assert_eq(items.length(), 3)
      assert_true(is_int(items[0], 1L))
      assert_true(is_int(items[1], 2L))
      assert_true(is_int(items[2], 3L))
    }
    _ => abort("expected an IN")
  }
  // The `Bool` of IsNull is `true` for IS NOT NULL, not a second node type.
  match filter_of("SELECT * FROM tesseract WHERE value IS NULL") {
    IsNull(Column(c), negated) => {
      assert_eq(c, "value")
      assert_false(negated)
    }
    _ => abort("expected IS NULL")
  }
  match filter_of("SELECT * FROM tesseract WHERE value IS NOT NULL") {
    IsNull(Column(c), negated) => {
      assert_eq(c, "value")
      assert_true(negated)
    }
    _ => abort("expected IS NOT NULL")
  }
  // `IS` with nothing that can be null is an error naming what it found.
  assert_eq(
    parse_failure("SELECT * FROM tesseract WHERE value IS 1").code,
    "INVALID_SYNTAX",
  )
}

///|
test "a function call is passed through without checking the name" {
  // The function table is the executor's. A parser that refused names it does
  // not know would turn "this engine has no hypot" into "this does not parse".
  let call = filter_of("SELECT * FROM tesseract WHERE length(value) > 2")
  match call {
    Binary(">", Call(name, args), rhs) => {
      assert_eq(name, "length")
      assert_eq(args.length(), 1)
      assert_true(is_column(args[0], "value"))
      assert_true(is_int(rhs, 2L))
    }
    _ => abort("expected length(value) > 2")
  }
  // Every name in the dialect's list, and one that is not in it. `name(...)` has
  // to parse whatever the argument is; only `*` is restricted.
  let calls = [
    "length(value)", "upper(value)", "lower(value)", "abs(digit)", "coords(grid_position)",
    "digits(digit)", "line(grid_position, 0)", "slab(grid_position, 1)", "peers(grid_position)",
    "count(*)", "sum(digit)", "min(digit)", "max(digit)", "avg(digit)", "hypot(x, y)",
  ]
  let mut i = 0
  while i < calls.length() {
    let s = spec_of("SELECT * FROM tesseract WHERE " + calls[i] + " = 1")
    match s.filter {
      Some(_) => ()
      None => abort("dropped the call: " + calls[i])
    }
    i = i + 1
  }
}

///|
test "star is legal only as the argument of count" {
  // `*` means "count the rows", it is not an expression, and it is only
  // meaningful to the aggregate that counts.
  match filter_of("SELECT * FROM tesseract WHERE count(*) > 1") {
    Binary(">", Call(name, args), _) => {
      assert_eq(name, "count")
      assert_eq(args.length(), 1)
      match args[0] {
        Star => ()
        _ => abort("expected a Star argument")
      }
    }
    _ => abort("expected count(*) > 1")
  }
  let bad = parse_failure("SELECT * FROM tesseract WHERE sum(*) > 1")
  assert_eq(bad.code, "INVALID_SYNTAX")
  assert_true(bad.message.contains("count(*)"))
  assert_true(
    parse_failure("SELECT * FROM tesseract WHERE * = 1").message.contains(
      "count(*)",
    ),
  )
}

///|
test "a comment inside a statement is not data" {
  assert_true(
    is_text_cmp(
      filter_of(
        "SELECT * -- everything past here is a note\nFROM tesseract WHERE key = 'a' /* and so is this */",
      ),
      "=",
      "key",
      "a",
    ),
  )
}

///|
test "keywords and the table name are case-insensitive" {
  let s = spec_of("SeLeCt * FrOm TeSsErAcT LiMiT 1")
  assert_true(s.star)
  match s.limit {
    Some(e) => assert_true(is_int(e, 1L))
    None => abort("LIMIT was dropped")
  }
  match parsed("CREATE DATABASE TESSERACT") {
    CreateDatabase(name) => assert_eq(name, "TESSERACT")
    _ => abort("expected CREATE DATABASE")
  }
}

///|
test "only the tesseract table is served, and the error says so" {
  let e = parse_failure("SELECT * FROM other")
  assert_eq(e.code, "INVALID_SYNTAX")
  assert_true(e.message.contains("other"))
  assert_true(e.message.contains("tesseract"))
  // The offset is the table name itself, not the start of the statement.
  assert_eq(e.at, 14)
  // A missing table name is named too, rather than reported as a stray token.
  let bare = parse_failure("SELECT * FROM 7")
  assert_true(bare.message.contains("tesseract"))
}

///|
test "a statement with a trailing semicolon is accepted, an empty one is not" {
  let bare = spec_of("SELECT * FROM tesseract")
  let semi = spec_of("SELECT * FROM tesseract;")
  assert_true(bare.star)
  assert_true(semi.star)
  assert_eq(semi.limit, bare.limit)
  // Two semicolons is not a statement with a semicolon.
  assert_eq(parse_failure("SELECT * FROM tesseract;;").code, "INVALID_SYNTAX")
  // Nothing to run is a failure, not a success that changed nothing: the old
  // layer reported EMPTY_SQL and a caller checking `success` could miss it.
  assert_eq(parse_failure("   ").code, "EMPTY_SQL")
  assert_eq(parse_failure(";").code, "EMPTY_SQL")
  assert_eq(parse_failure("").code, "EMPTY_SQL")
}

///|
test "text after the statement is refused, not ignored" {
  let e = parse_failure("SELECT * FROM tesseract WHERE key = 'a' junk")
  assert_eq(e.code, "INVALID_SYNTAX")
  assert_true(e.message.contains("junk"))
  assert_eq(e.at, 40)
}

///|
test "every error carries an offset into the source" {
  // None of these statements is wrong at its first character, so none of these
  // offsets is zero. An error *on* the first token is at zero - see the
  // UNSUPPORTED_SQL test - and an error on the token that ended the statement is
  // at the statement's length. Both are positions in the source, which is what
  // a caller needs.
  let bad = [
    "SELECT * FROM other", "SELECT * FROM tesseract WHERE key =", "SELECT * FROM tesseract WHERE (key = 'a'",
    "UPDATE tesseract SET = 'a'", "INSERT INTO tesseract (key, value) VALUES ('a')",
    "SELECT * FROM tesseract ORDER key", "SELECT * FROM tesseract GROUP digit", "SELECT * FROM tesseract WHERE key = 'a",
    "DELETE tesseract", "CREATE TABLE tesseract", "SELECT * FROM tesseract WHERE sum(*) > 1",
  ]
  let mut i = 0
  while i < bad.length() {
    let e = parse_failure(bad[i])
    assert_true(e.at > 0)
    // The offset is at most the length of the statement: an error on the token
    // that ended the statement points at the end of it.
    assert_true(e.at <= bad[i].length())
    assert_true(e.message != "")
    i = i + 1
  }
}

///|
test "an INSERT keeps its columns, its values and its target" {
  match parsed("INSERT INTO tesseract (key, value) VALUES ('a', 'b')") {
    Insert(cols, vals, target) => {
      assert_eq(cols.length(), 2)
      assert_eq(cols[0], "key")
      assert_eq(cols[1], "value")
      assert_eq(vals.length(), 2)
      match vals[0] {
        Literal(Text(v)) => assert_eq(v, "a")
        _ => abort("expected the key literal")
      }
      match target {
        None => ()
        _ => abort("no AT clause should mean Target::None")
      }
    }
    _ => abort("expected an INSERT")
  }
  match parsed("INSERT INTO tesseract (key) VALUES ('a') AT 42") {
    Insert(_, _, Position(v)) => assert_eq(v, 42L)
    _ => abort("expected AT 42")
  }
  // The 4D form stays four coordinates: the parser has no lattice, so it cannot
  // resolve them to a position, and a target of the wrong length is a typo.
  match parsed("INSERT INTO tesseract (key) VALUES ('a') AT (1,2,0,2)") {
    Insert(_, _, Coords(v)) => {
      assert_eq(v.length(), 4)
      assert_eq(v[0], 1L)
      assert_eq(v[3], 2L)
    }
    _ => abort("expected AT (1,2,0,2)")
  }
  assert_eq(
    parse_failure("INSERT INTO tesseract (key) VALUES ('a') AT (1,2)").code,
    "INVALID_SYNTAX",
  )
  assert_eq(
    parse_failure("INSERT INTO tesseract (key) VALUES ('a') AT x").code,
    "INVALID_SYNTAX",
  )
  // Out of range is the executor's to report: the parser has no lattice, so
  // (9,9,9,9) is a well-formed address on a side-9 lattice.
  match parsed("INSERT INTO tesseract (key) VALUES ('a') AT (9,9,9,9)") {
    Insert(_, _, Coords(v)) => assert_eq(v.length(), 4)
    _ => abort("expected AT (9,9,9,9)")
  }
  // `AT` with nothing after it is an error, not a target of zero.
  assert_eq(
    parse_failure("INSERT INTO tesseract (key) VALUES ('a') AT").code,
    "INVALID_SYNTAX",
  )
}

///|
test "an INSERT whose column list and value list disagree is INVALID_COLUMNS" {
  // Both lists parsed. This is the code the old layer already reported, and
  // folding it into INVALID_SYNTAX would lose the one distinction that tells a
  // caller whether to fix the statement or fix the caller.
  let e = parse_failure(
    "INSERT INTO tesseract (key, value, digit) VALUES ('a')",
  )
  assert_eq(e.code, "INVALID_COLUMNS")
  assert_true(e.at > 0)
}

///|
test "an escaped quote survives the whole statement" {
  match parsed("INSERT INTO tesseract (key, value) VALUES ('a', 'it''s')") {
    Insert(_, vals, _) =>
      match vals[1] {
        Literal(Text(v)) => assert_eq(v, "it's")
        _ => abort("expected the escaped literal")
      }
    _ => abort("expected an INSERT")
  }
  match parsed("INSERT INTO tesseract (key, value) VALUES ('a', 'it\\'s')") {
    Insert(_, vals, _) =>
      match vals[1] {
        Literal(Text(v)) => assert_eq(v, "it's")
        _ => abort("expected the escaped literal")
      }
    _ => abort("expected an INSERT")
  }
}

///|
test "UPDATE takes several assignments and an optional WHERE" {
  match parsed("UPDATE tesseract SET value = '2', digit = 3 WHERE key = 'a'") {
    Update(assigns, filter) => {
      assert_eq(assigns.length(), 2)
      assert_eq(assigns[0].column, "value")
      assert_eq(assigns[1].column, "digit")
      match assigns[1].value {
        Literal(Int(v)) => assert_eq(v, 3L)
        _ => abort("expected digit = 3")
      }
      match filter {
        Some(e) => assert_true(is_text_cmp(e, "=", "key", "a"))
        None => abort("the WHERE was dropped")
      }
    }
    _ => abort("expected an UPDATE")
  }
  match parsed("UPDATE tesseract SET value = '2'") {
    Update(assigns, filter) => {
      assert_eq(assigns.length(), 1)
      assert_true(filter == None)
    }
    _ => abort("expected an UPDATE")
  }
}

///|
test "DELETE takes an optional WHERE, and a bare one is a real statement" {
  match parsed("DELETE FROM tesseract WHERE key = 'a'") {
    Delete(Some(e)) => assert_true(is_text_cmp(e, "=", "key", "a"))
    _ => abort("expected a DELETE with a WHERE")
  }
  match parsed("DELETE FROM tesseract;") {
    Delete(filter) => assert_true(filter == None)
    _ => abort("expected a DELETE")
  }
}

///|
test "DISTINCT and GROUP BY are carried, not inferred" {
  let s = spec_of("SELECT DISTINCT digit FROM tesseract GROUP BY digit, x")
  assert_true(s.distinct)
  assert_false(s.star)
  assert_eq(s.columns.length(), 1)
  assert_true(is_column(s.columns[0], "digit"))
  assert_eq(s.group_by.length(), 2)
  assert_true(is_column(s.group_by[0], "digit"))
  assert_true(is_column(s.group_by[1], "x"))
  // SELECT * and a column list do not overlap.
  let star = spec_of("SELECT * FROM tesseract")
  assert_true(star.star)
  assert_eq(star.columns.length(), 0)
  assert_false(star.distinct)
}

///|
test "the select list takes expressions, including count(*)" {
  // This list was `Array[String]` and the select list refused `count(*)` for
  // exactly that reason. Holding `Expr` is the fix that keeps the refusal from
  // being needed: there is nowhere for a fragment of syntax to hide.
  let agg = spec_of("SELECT count(*) FROM tesseract")
  assert_false(agg.star)
  assert_eq(agg.columns.length(), 1)
  match agg.columns[0] {
    Call(name, args) => {
      assert_eq(name, "count")
      assert_eq(args.length(), 1)
      // Matched, not compared: a blackbox test cannot construct a package enum
      // variant (`Cannot create values of the read-only type: Star`), so the
      // assertion has to be a pattern.
      match args[0] {
        Star => assert_true(true)
        _ => abort("expected * inside count()")
      }
    }
    _ => abort("expected count(*)")
  }
  let cols = spec_of("SELECT key, value, digit FROM tesseract")
  assert_eq(cols.columns.length(), 3)
  assert_true(is_column(cols.columns[2], "digit"))
  let arithmetic = spec_of("SELECT digit + 1 FROM tesseract")
  match arithmetic.columns[0] {
    Binary(op, _, _) => assert_eq(op, "+")
    _ => abort("expected digit + 1")
  }
}

///|
test "clause order is the grammar's, and a clause out of order is refused" {
  let s = spec_of(
    "SELECT * FROM tesseract WHERE digit = 1 GROUP BY x ORDER BY key DESC LIMIT 1 OFFSET 2",
  )
  assert_true(
    is_int_cmp(
      match s.filter {
        Some(e) => e
        None => abort("no filter")
      },
      "=",
      "digit",
      1L,
    ),
  )
  assert_eq(s.group_by.length(), 1)
  assert_eq(s.order_by.length(), 1)
  match s.limit {
    Some(e) => assert_true(is_int(e, 1L))
    None => abort("LIMIT was dropped")
  }
  match s.offset {
    Some(e) => assert_true(is_int(e, 2L))
    None => abort("OFFSET was dropped")
  }
  // LIMIT before WHERE is not silently reordered.
  assert_eq(
    parse_failure("SELECT * FROM tesseract LIMIT 1 WHERE digit = 1").code,
    "INVALID_SYNTAX",
  )
}

///|
test "transaction control parses in every spelling the grammar allows" {
  // `BEGIN` and `COMMIT` carry no name, so they are checked by matching the
  // shape: this toolchain will not let a blackbox test build a package enum.
  match parsed("BEGIN") {
    Begin => ()
    _ => abort("expected BEGIN")
  }
  match parsed("begin transaction") {
    Begin => ()
    _ => abort("expected BEGIN TRANSACTION")
  }
  match parsed("COMMIT") {
    Commit => ()
    _ => abort("expected COMMIT")
  }
  match parsed("rollback") {
    Rollback => ()
    _ => abort("expected ROLLBACK")
  }
  // A savepoint name is a label the client chose, so these compare by matching
  // rather than by building a `Stmt`.
  match parsed("SAVEPOINT sp1") {
    Savepoint(n) => assert_eq(n, "sp1")
    _ => abort("expected SAVEPOINT")
  }
  match parsed("ROLLBACK TO sp1") {
    RollbackTo(n) => assert_eq(n, "sp1")
    _ => abort("expected ROLLBACK TO")
  }
  match parsed("ROLLBACK TO SAVEPOINT sp1") {
    RollbackTo(n) => assert_eq(n, "sp1")
    _ => abort("expected ROLLBACK TO SAVEPOINT")
  }
  match parsed("RELEASE sp1") {
    Release(n) => assert_eq(n, "sp1")
    _ => abort("expected RELEASE")
  }
  match parsed("RELEASE SAVEPOINT sp1") {
    Release(n) => assert_eq(n, "sp1")
    _ => abort("expected RELEASE SAVEPOINT")
  }
  // A savepoint is not a table, so it is not checked against `tesseract`.
  match parsed("SAVEPOINT my_mark") {
    Savepoint(n) => assert_eq(n, "my_mark")
    _ => abort("expected SAVEPOINT")
  }
  // ...and a missing name is still a syntax error.
  assert_eq(parse_failure("SAVEPOINT").code, "INVALID_SYNTAX")
  assert_eq(parse_failure("RELEASE").code, "INVALID_SYNTAX")
  assert_eq(parse_failure("BEGIN BOGUS").code, "INVALID_SYNTAX")
}

///|
test "a statement this dialect does not serve says UNSUPPORTED_SQL" {
  // Naming it separately is what lets a client tell "you asked for something
  // else" from "you asked for this and got it wrong".
  let drop = parse_failure("DROP TABLE tesseract")
  assert_eq(drop.code, "UNSUPPORTED_SQL")
  assert_true(drop.message.contains("DROP"))
  // The offending token is the first character of the statement, so zero is the
  // correct offset here rather than a missing one. "Non-zero" is not a property
  // an error can have when its token is the first one; what every error has is
  // an offset that points at the token that stopped it.
  assert_eq(drop.at, 0)
  // A stray punctuation mark is a malformed statement, not an unsupported one.
  assert_eq(parse_failure("?").code, "INVALID_SYNTAX")
  // A recognised verb with a broken body is a syntax error too, so a client can
  // tell "not implemented" from "wrong".
  assert_eq(
    parse_failure("SELECT * FROM tesseract junk").code,
    "INVALID_SYNTAX",
  )
  assert_eq(parse_failure("SELECT FROM tesseract").code, "INVALID_SYNTAX")
}

///|
test "a bare NULL is a literal and IS NULL is a predicate" {
  // `SqlValue::Null` is part of the AST, and a variant the parser can never
  // produce is one the executor has no agreed way to be handed.
  match filter_of("SELECT * FROM tesseract WHERE digit = NULL") {
    Binary("=", Column(c), Literal(v)) => {
      assert_eq(c, "digit")
      match v {
        Null => ()
        _ => abort("expected a Null literal")
      }
    }
    _ => abort("expected digit = NULL")
  }
}

///|
test "a lexical failure arrives as a parse failure with its offset" {
  let e = parse_failure("SELECT * FROM tesseract WHERE key = 'a")
  assert_eq(e.code, "INVALID_SYNTAX")
  assert_true(e.message.contains("Unterminated"))
  // The opening quote, which is at offset 36 in this statement.
  assert_eq(e.at, 36)
  let n = parse_failure("SELECT * FROM tesseract WHERE digit = 12abc")
  assert_true(n.message.contains("Malformed"))
  // The offending character, which is the `a` at offset 40.
  assert_eq(n.at, 40)
  let u = parse_failure("SELECT * FROM tesseract /* never closed")
  assert_true(u.at > 0)
  assert_true(u.message.contains("Unexpected"))
}

///|
test "parse_error_message keeps the message and adds where it happened" {
  let m = @tesseract.parse_error_message(parse_failure("SELECT * FROM other"))
  assert_true(m.contains("other"))
  assert_true(m.contains("14"))
}
