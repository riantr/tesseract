///|
/// The parser: one statement of SQL text to one `Stmt`.
///
/// This replaces the string scanning `sql.mbt` did, and the replacement is not
/// a refactor. Four behaviours were measured against the real CLI before any of
/// this was written:
///
/// | statement                                        | measured        | correct |
/// |--------------------------------------------------|-----------------|---------|
/// | `WHERE key='alpha' AND key='beta'`               | 1 row (`beta`)  | 0 rows  |
/// | `WHERE key='alpha' OR key='beta'`                | `INVALID_SYNTAX`| 1 row   |
/// | `SELECT * FROM tesseract LIMIT 1`                | 3 rows          | 1 row   |
/// | `SELECT * FROM tesseract ORDER BY key DESC`      | insertion order | sorted  |
/// | `WHERE digit=1+1`                                | `INVALID_SYNTAX`| digit 2 |
///
/// The root cause is one thing, and it is a modelling failure rather than a
/// scanning failure: the old `WHERE` was a struct holding at most one predicate
/// per field, so `key = 'alpha' AND key = 'beta'` could not be *written down*.
/// The second conjunct overwrote the first and the query answered a different
/// question than the one it was asked, which is the one direction of error a
/// caller cannot see. `Expr::Binary` nests instead, so the tree of the question
/// is the tree in memory.
///
/// The rule that follows from that, and the one this file is built around:
/// **a clause the parser accepts is a clause the AST can carry.** Nothing is
/// scanned for, recognised and then dropped. `LIMIT`, `OFFSET`, `ORDER BY`,
/// `GROUP BY`, `DISTINCT` and `AT` all have fields, and the four error codes
/// below are the only ways a statement can be refused. A clause that could not
/// be represented would have been refused, not ignored - the old `LIMIT 1`
/// returning three rows is what ignoring looks like.
///
/// Error codes, kept to the vocabulary `sql.mbt` already reports so the CLI's
/// error strings do not change shape under the new front half:
///
/// - `INVALID_SYNTAX` — malformed, or a token that has no place in the
///   grammar. The default, and by far the most common.
/// - `EMPTY_SQL` — nothing to run: only whitespace, or only `;`.
/// - `INVALID_COLUMNS` — an `INSERT` whose column list and value list disagree
///   in length. Not a syntax fault: both lists are well formed, they just do
///   not describe the same row.
/// - `UNSUPPORTED_SQL` — a statement this dialect does not serve, such as
///   `DROP TABLE`. Naming it separately is what lets a client tell "you asked
///   for something else" from "you asked for this and got it wrong".

///|
/// A statement that did not parse, with the offset of the offending token.
///
/// `at` comes straight from `Token.at`, so it is a position in the text the
/// caller passed rather than a line or column the caller has to reconstruct.
pub struct ParseError {
  code : String
  message : String
  at : Int32
} derive(Eq, Debug)

///|
pub extend ParseError with Eq::{equal, not_equal}

///|
pub extend ParseError with @debug.Debug::{to_repr}

///|
/// A human-readable rendering of a parse failure.
///
/// The message names the token that stopped the parse, so "expected `)`" on its
/// own is not enough to find a typo in a statement the caller may have built
/// rather than typed.
pub fn parse_error_message(e : ParseError) -> String {
  e.message + " at offset " + e.at.to_string()
}

///|
/// The cursor over the token stream.
///
/// One position, no look-ahead beyond "is the next token the end". Every
/// grammar rule stops where it stops because an operator it does not recognise
/// is not an operator - which is why the clause keywords work without any
/// scanning for them: `WHERE a = 1 GROUP BY x` ends the expression at `GROUP`
/// because `GROUP` is not an operator, not because anything looked ahead.
priv struct P {
  toks : Array[Token]
  mut pos : Int32
}

///|
/// What a token is, for an error message.
fn describe(t : Token) -> String {
  match t.kind {
    Ident(s) => "`" + s + "`"
    IntLit(n) => "integer " + n.to_string()
    Text(s) => "string literal `" + s + "`"
    Punct(s) => "`" + s + "`"
    Eof => "end of statement"
  }
}

///|
/// A syntax error at `t`.
fn syntax_at(t : Token, what : String) -> ParseError {
  {
    code: "INVALID_SYNTAX",
    message: what + ", found " + describe(t),
    at: t.at,
  }
}

///|
/// A syntax error at the cursor.
fn syntax_here(p : P, what : String) -> ParseError {
  syntax_at(p.toks[p.pos], what)
}

///|
/// The offset a lexical failure is about.
fn lex_error_at(e : LexError) -> Int32 {
  match e {
    UnterminatedString(at) => at
    UnexpectedChar(at, _) => at
    BadNumber(at) => at
  }
}

///|
/// A lexical failure as a parse failure.
///
/// The code is `INVALID_SYNTAX` in every case. A statement that does not tokenise
/// is a malformed statement, and the lexer already said precisely where; keeping
/// the two vocabularies apart here would only mean a caller has to know which
/// half of the pipeline rejected it.
fn lex_as_parse_error(e : LexError) -> ParseError {
  {
    code: "INVALID_SYNTAX",
    message: lex_error_message(e),
    at: lex_error_at(e),
  }
}

///|
/// The token under the cursor.
fn cur(p : P) -> Token {
  p.toks[p.pos]
}

///|
/// True when the cursor is on the final `Eof`.
fn at_eof(p : P) -> Bool {
  match p.toks[p.pos].kind {
    Eof => true
    _ => false
  }
}

///|
/// True when the token after the cursor is the final `Eof`.
///
/// Used only to tell a bare `;` from a statement that has not started yet.
fn next_is_eof(p : P) -> Bool {
  if p.pos + 1 >= p.toks.length() {
    return true
  }
  match p.toks[p.pos + 1].kind {
    Eof => true
    _ => false
  }
}

///|
/// True when the cursor is on the punctuator `s`.
fn at_punct(p : P, s : String) -> Bool {
  match p.toks[p.pos].kind {
    Punct(x) => x == s
    _ => false
  }
}

///|
/// True when the cursor is on the keyword `kw`, in any case.
fn at_kw(p : P, kw : String) -> Bool {
  match p.toks[p.pos].kind {
    Ident(x) => eq_ci(x, kw)
    _ => false
  }
}

///|
/// Consumes the punctuator `s`, or reports what is there instead.
///
/// `ParseError?` rather than `Result[Unit, ParseError]`: this toolchain has no
/// `?` propagation operator to drop the error in from a statement position, so
/// every call site spells out the two arms. Returning `None` for success keeps
/// the `None` arm to a bare `()`.
fn want_punct(p : P, s : String) -> ParseError? {
  if at_punct(p, s) {
    p.pos = p.pos + 1
    return None
  }
  Some(syntax_here(p, "expected `" + s + "`"))
}

///|
/// Consumes the keyword `kw`, or reports what is there instead.
fn want_kw(p : P, kw : String) -> ParseError? {
  if at_kw(p, kw) {
    p.pos = p.pos + 1
    return None
  }
  Some(syntax_here(p, "expected `" + kw + "`"))
}

///|
/// Consumes the identifier at the cursor and returns it verbatim.
fn ident_name(p : P, what : String) -> Result[String, ParseError] {
  match p.toks[p.pos].kind {
    Ident(s) => {
      p.pos = p.pos + 1
      Ok(s)
    }
    _ => Err(syntax_here(p, what))
  }
}

///|
/// Consumes a table name and checks it.
///
/// The name is returned, and every caller then drops it: no `Stmt` constructor
/// carries a table name, because this dialect has exactly one table. So this is
/// the *only* place `SELECT * FROM other` can be refused, and it is checked
/// before the statement is built rather than by the executor afterwards.
///
/// The comparison is case-insensitive, as the rest of the grammar is; the
/// original case is kept so a saved statement round-trips unchanged.
fn expect_table(p : P) -> Result[String, ParseError] {
  let t = cur(p)
  match t.kind {
    Ident(name) => {
      if !eq_ci(name, "tesseract") {
        return Err(
          syntax_at(
            t,
            "unknown table `" + name + "`, this build serves only `tesseract`",
          ),
        )
      }
      p.pos = p.pos + 1
      Ok(name)
    }
    _ => Err(syntax_at(t, "expected the table name `tesseract`"))
  }
}

///|
/// The whole expression grammar, loosest operator first.
fn parse_expr(p : P) -> Result[Expr, ParseError] {
  parse_or(p)
}

///|
/// `a OR b OR c`
fn parse_or(p : P) -> Result[Expr, ParseError] {
  let mut lhs = match parse_and(p) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  while true {
    if !at_kw(p, "OR") {
      break
    }
    p.pos = p.pos + 1
    let rhs = match parse_and(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    lhs = Binary("OR", lhs, rhs)
  }
  Ok(lhs)
}

///|
/// `a AND b AND c`
///
/// Left-associative and un-flattened on purpose: `a AND b AND c` is
/// `(a AND b) AND c` and keeps all three. Flattening to a list would be tidier
/// and would still be correct, but a tree with one shape per spelling of a
/// question is easier to check against the question.
fn parse_and(p : P) -> Result[Expr, ParseError] {
  let mut lhs = match parse_not(p) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  while true {
    if !at_kw(p, "AND") {
      break
    }
    p.pos = p.pos + 1
    let rhs = match parse_not(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    lhs = Binary("AND", lhs, rhs)
  }
  Ok(lhs)
}

///|
/// `NOT a`.
///
/// `NOT` sits between `AND` and the comparisons, so `NOT a = 1 AND b = 2` is
/// `(NOT (a = 1)) AND (b = 2)` - the negation takes the comparison, not the
/// conjunction. The other order would be a different statement.
fn parse_not(p : P) -> Result[Expr, ParseError] {
  if at_kw(p, "NOT") {
    p.pos = p.pos + 1
    let inner = match parse_not(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    return Ok(Not(inner))
  }
  parse_cmp(p)
}

///|
/// The comparison operator under the cursor, if there is one.
///
/// `!=` is folded into `<>` here. The AST has one not-equal operator, and two
/// spellings reaching the executor would mean an executor that pattern-matches
/// on the operator string has to handle both - and a spelling it forgets matches
/// nothing, quietly.
fn cmp_op(p : P) -> String? {
  match p.toks[p.pos].kind {
    Punct(s) =>
      if s == "=" || s == "<>" || s == "<" || s == "<=" || s == ">" || s == ">=" {
        Some(s)
      } else if s == "!=" {
        Some("<>")
      } else {
        None
      }
    _ => None
  }
}

///|
/// One comparison, `LIKE`, `IN (...)` or `IS [NOT] NULL`.
///
/// At most one. `a = b = c` is not a chain here: the second `=` is left for the
/// statement-level check, which refuses it naming the operator, rather than
/// being folded into a rule the grammar does not state.
fn parse_cmp(p : P) -> Result[Expr, ParseError] {
  let lhs = match parse_add(p) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  match cmp_op(p) {
    Some(op) => {
      p.pos = p.pos + 1
      let rhs = match parse_add(p) {
        Ok(e) => e
        Err(err) => return Err(err)
      }
      return Ok(Binary(op, lhs, rhs))
    }
    None => ()
  }
  if at_kw(p, "LIKE") {
    p.pos = p.pos + 1
    let rhs = match parse_add(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    return Ok(Like(lhs, rhs))
  }
  if at_kw(p, "IN") {
    p.pos = p.pos + 1
    return parse_in_list(p, lhs)
  }
  if at_kw(p, "IS") {
    p.pos = p.pos + 1
    let mut negated = false
    if at_kw(p, "NOT") {
      negated = true
      p.pos = p.pos + 1
    }
    if !at_kw(p, "NULL") {
      return Err(syntax_here(p, "expected NULL after IS"))
    }
    p.pos = p.pos + 1
    return Ok(IsNull(lhs, negated))
  }
  Ok(lhs)
}

///|
/// The `( ... )` of an `IN`, after the keyword.
fn parse_in_list(p : P, lhs : Expr) -> Result[Expr, ParseError] {
  match want_punct(p, "(") {
    None => ()
    Some(e) => return Err(e)
  }
  let items : Array[Expr] = []
  if at_punct(p, ")") {
    // `x IN ()` is legal here. What it means - always false, or an error - is
    // the executor's call; the grammar has a list between the brackets and an
    // empty one is a list.
    p.pos = p.pos + 1
    return Ok(In(lhs, items))
  }
  while true {
    let e = match parse_expr(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    items.push(e)
    if at_punct(p, ",") {
      p.pos = p.pos + 1
      continue
    }
    break
  }
  match want_punct(p, ")") {
    None => ()
    Some(e) => return Err(e)
  }
  Ok(In(lhs, items))
}

///|
/// `+` or `-`, if the cursor is on one.
fn add_op(p : P) -> String? {
  if at_punct(p, "+") {
    Some("+")
  } else if at_punct(p, "-") {
    Some("-")
  } else {
    None
  }
}

///|
/// `*`, `/` or `%`, if the cursor is on one.
fn mul_op(p : P) -> String? {
  if at_punct(p, "*") {
    Some("*")
  } else if at_punct(p, "/") {
    Some("/")
  } else if at_punct(p, "%") {
    Some("%")
  } else {
    None
  }
}

///|
/// Additive, tighter than comparison.
fn parse_add(p : P) -> Result[Expr, ParseError] {
  let mut lhs = match parse_mul(p) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  while true {
    match add_op(p) {
      Some(op) => {
        p.pos = p.pos + 1
        let rhs = match parse_mul(p) {
          Ok(e) => e
          Err(err) => return Err(err)
        }
        lhs = Binary(op, lhs, rhs)
      }
      None => break
    }
  }
  Ok(lhs)
}

///|
/// Multiplicative, tighter than additive.
///
/// So `2 * 3 + 4` is `(2 * 3) + 4`, and `WHERE digit = 1 + 1` compares the
/// column against two rather than failing: the old parser had no arithmetic at
/// all, so it reported `INVALID_SYNTAX` for a statement the grammar here allows.
fn parse_mul(p : P) -> Result[Expr, ParseError] {
  let mut lhs = match parse_unary(p) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  while true {
    match mul_op(p) {
      Some(op) => {
        p.pos = p.pos + 1
        let rhs = match parse_unary(p) {
          Ok(e) => e
          Err(err) => return Err(err)
        }
        lhs = Binary(op, lhs, rhs)
      }
      None => break
    }
  }
  Ok(lhs)
}

///|
/// `-x`, or a unary `+`.
///
/// Unary `+` is not in the grammar's operator list and is accepted here only
/// because a sign is what a caller writes in front of a number they copied from
/// somewhere signed. It produces no node: `+x` is `x`, and a `Binary("+", 0, x)`
/// stand-in would put a node in the tree that means nothing the executor has to
/// answer for.
fn parse_unary(p : P) -> Result[Expr, ParseError] {
  if at_punct(p, "-") {
    p.pos = p.pos + 1
    let inner = match parse_unary(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    return Ok(Neg(inner))
  }
  if at_punct(p, "+") {
    p.pos = p.pos + 1
    return parse_unary(p)
  }
  parse_primary(p)
}

///|
/// A literal, a column, a call, a parenthesised expression.
fn parse_primary(p : P) -> Result[Expr, ParseError] {
  if at_punct(p, "(") {
    p.pos = p.pos + 1
    let inner = match parse_expr(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    match want_punct(p, ")") {
      None => ()
      Some(e) => return Err(e)
    }
    return Ok(inner)
  }
  let t = cur(p)
  match t.kind {
    IntLit(n) => {
      p.pos = p.pos + 1
      Ok(Literal(Int(n)))
    }
    Text(s) => {
      p.pos = p.pos + 1
      Ok(Literal(Text(s)))
    }
    Ident(name) => {
      p.pos = p.pos + 1
      if at_punct(p, "(") {
        return parse_call(p, name)
      }
      // A bare `NULL` is the only literal the grammar spells as a word. It is
      // not in the grammar's `primary` list, and it is here for one reason:
      // `SqlValue::Null` is part of the AST, and a variant the parser can never
      // produce is a variant the executor has no agreed way to be handed one.
      // `IS NULL` still builds `IsNull` - this is the bare literal, so
      // `digit = NULL` is an expression and `digit IS NULL` is a predicate.
      if eq_ci(name, "NULL") {
        return Ok(Literal(Null))
      }
      Ok(Column(name))
    }
    Punct(s) =>
      if s == "*" {
        Err(syntax_at(t, "`*` is only legal as the argument of count(*)"))
      } else {
        Err(syntax_at(t, "expected a value, a column or a function call"))
      }
    Eof => Err(syntax_at(t, "expected a value, a column or a function call"))
  }
}

///|
/// The argument list of a call, with the cursor on its `(`.
///
/// The name is not checked. The function table is the executor's, and a parser
/// that refused names it does not recognise would turn "this engine has no
/// `hypot`" into "this statement does not parse" - a client unable to tell the
/// two apart. Arity is a different matter and *is* checked, for the one case
/// that is syntactically fixed: `*` means "count the rows", it is not an
/// expression, and it is only meaningful to the aggregate that counts.
fn parse_call(p : P, name : String) -> Result[Expr, ParseError] {
  let open = cur(p)
  p.pos = p.pos + 1
  let args : Array[Expr] = []
  let star_only = at_punct(p, "*")
  if star_only {
    p.pos = p.pos + 1
    args.push(Star)
  } else if !at_punct(p, ")") {
    while true {
      let e = match parse_expr(p) {
        Ok(e) => e
        Err(err) => return Err(err)
      }
      args.push(e)
      if at_punct(p, ",") {
        p.pos = p.pos + 1
        continue
      }
      break
    }
  }
  match want_punct(p, ")") {
    None => ()
    Some(e) => return Err(e)
  }
  if star_only && !eq_ci(name, "count") {
    return Err(
      syntax_at(
        open,
        "`*` is only legal as the argument of count(*), not of `" + name + "`",
      ),
    )
  }
  Ok(Call(name, args))
}

///|
/// A signed integer literal, for `AT` targets.
///
/// The sign is folded into the number here rather than left as a `Neg` node,
/// because `Target` holds an `Int64` and a target of `-1` is an out-of-range
/// cell for the executor to report, not a negated expression it cannot hold.
fn parse_signed_int(p : P, what : String) -> Result[Int64, ParseError] {
  let mut neg = false
  if at_punct(p, "-") {
    neg = true
    p.pos = p.pos + 1
  } else if at_punct(p, "+") {
    p.pos = p.pos + 1
  }
  match p.toks[p.pos].kind {
    IntLit(n) => {
      p.pos = p.pos + 1
      Ok(if neg { -n } else { n })
    }
    _ => Err(syntax_here(p, what))
  }
}

///|
/// The `AT <target>` of an `INSERT`.
///
/// The coordinate form is not resolved into a position. The old parser needed a
/// lattice to do that, so `AT (1,1,1,0)` meant different cells at side 3 and at
/// side 4 and the statement could not be parsed without knowing which one it was
/// for. Carrying the four coordinates leaves the answer with the executor, which
/// is where the lattice is. The count is still checked here, because four is not
/// a property of the lattice - it is the number of axes, and a target of the
/// wrong length is a typo rather than an out-of-range cell.
fn parse_target(p : P) -> Result[Target, ParseError] {
  if at_punct(p, "(") {
    let open = cur(p)
    p.pos = p.pos + 1
    let vals : Array[Int64] = []
    while true {
      let v = match parse_signed_int(p, "expected a coordinate") {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      vals.push(v)
      if at_punct(p, ",") {
        p.pos = p.pos + 1
        continue
      }
      break
    }
    match want_punct(p, ")") {
      None => ()
      Some(e) => return Err(e)
    }
    if vals.length() != DIM.to_int() {
      return Err(
        syntax_at(
          open,
          "AT (x,y,z,w) needs four coordinates, found " +
          vals.length().to_string(),
        ),
      )
    }
    return Ok(Coords(vals))
  }
  let v = match
    parse_signed_int(p, "expected a position or (x,y,z,w) after AT") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok(Position(v))
}

///|
/// `CREATE DATABASE <name>`
fn parse_create(p : P) -> Result[Stmt, ParseError] {
  p.pos = p.pos + 1
  if !at_kw(p, "DATABASE") {
    return Err(syntax_here(p, "expected DATABASE after CREATE"))
  }
  p.pos = p.pos + 1
  let name = match expect_table(p) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok(CreateDatabase(name))
}

///|
/// `INSERT INTO <name> ( <col>... ) VALUES ( <expr>... ) [ AT <target> ]`
fn parse_insert_stmt(p : P) -> Result[Stmt, ParseError] {
  p.pos = p.pos + 1
  match want_kw(p, "INTO") {
    None => ()
    Some(e) => return Err(e)
  }
  match expect_table(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match want_punct(p, "(") {
    None => ()
    Some(e) => return Err(e)
  }
  let columns : Array[String] = []
  while true {
    let t = cur(p)
    if at_punct(p, ")") {
      return Err(syntax_at(t, "expected a column name before `)`"))
    }
    let name = match ident_name(p, "expected a column name") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    columns.push(name)
    if at_punct(p, ",") {
      p.pos = p.pos + 1
      continue
    }
    break
  }
  match want_punct(p, ")") {
    None => ()
    Some(e) => return Err(e)
  }
  match want_kw(p, "VALUES") {
    None => ()
    Some(e) => return Err(e)
  }
  match want_punct(p, "(") {
    None => ()
    Some(e) => return Err(e)
  }
  let values : Array[Expr] = []
  while true {
    let t = cur(p)
    if at_punct(p, ")") {
      return Err(syntax_at(t, "expected a value before `)`"))
    }
    let e = match parse_expr(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    values.push(e)
    if at_punct(p, ",") {
      p.pos = p.pos + 1
      continue
    }
    break
  }
  match want_punct(p, ")") {
    None => ()
    Some(e) => return Err(e)
  }
  if columns.length() != values.length() {
    // `INVALID_COLUMNS` and not `INVALID_SYNTAX`: both lists parsed. This is the
    // code `sql.mbt` already reported for this case, and folding it into the
    // syntax code would lose the one distinction that tells a caller whether to
    // fix the statement or fix the caller.
    return Err({
      code: "INVALID_COLUMNS",
      message: "INSERT names " +
      columns.length().to_string() +
      " columns and gives " +
      values.length().to_string() +
      " values",
      at: cur(p).at,
    })
  }
  let mut target = Target::None
  if at_kw(p, "AT") {
    p.pos = p.pos + 1
    match parse_target(p) {
      Ok(t) => target = t
      Err(e) => return Err(e)
    }
  }
  Ok(Insert(columns, values, target))
}

///|
/// `UPDATE <name> SET <col> = <expr> [ , ... ] [ WHERE <expr> ]`
fn parse_update_stmt(p : P) -> Result[Stmt, ParseError] {
  p.pos = p.pos + 1
  match expect_table(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match want_kw(p, "SET") {
    None => ()
    Some(e) => return Err(e)
  }
  let assigns : Array[Assignment] = []
  while true {
    let column = match ident_name(p, "expected a column name to assign") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match want_punct(p, "=") {
      None => ()
      Some(e) => return Err(e)
    }
    let value = match parse_expr(p) {
      Ok(e) => e
      Err(err) => return Err(err)
    }
    assigns.push({ column, value, })
    if at_punct(p, ",") {
      p.pos = p.pos + 1
      continue
    }
    break
  }
  let mut filter : Expr? = None
  if at_kw(p, "WHERE") {
    p.pos = p.pos + 1
    match parse_expr(p) {
      Ok(v) => filter = Some(v)
      Err(e) => return Err(e)
    }
  }
  Ok(Update(assigns, filter))
}

///|
/// `DELETE FROM <name> [ WHERE <expr> ]`
fn parse_delete_stmt(p : P) -> Result[Stmt, ParseError] {
  p.pos = p.pos + 1
  match want_kw(p, "FROM") {
    None => ()
    Some(e) => return Err(e)
  }
  match expect_table(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let mut filter : Expr? = None
  if at_kw(p, "WHERE") {
    p.pos = p.pos + 1
    match parse_expr(p) {
      Ok(v) => filter = Some(v)
      Err(e) => return Err(e)
    }
  }
  Ok(Delete(filter))
}

///|
/// One `ORDER BY` term.
fn parse_order_term(p : P) -> Result[OrderTerm, ParseError] {
  let e = match parse_expr(p) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let mut descending = false
  if at_kw(p, "DESC") {
    descending = true
    p.pos = p.pos + 1
  } else if at_kw(p, "ASC") {
    // Recorded as the absence of `DESC`, so `ASC` and no direction are the same
    // node and an executor needs one comparison rather than two.
    p.pos = p.pos + 1
  }
  Ok({ expr: e, descending, })
}

///|
/// The select list: `*`, or a list of expressions.
///
/// Expressions, not bare names, so `SELECT count(*)`, `SELECT digit + 1` and
/// `SELECT upper(key)` are all selectable. The earlier version of this function
/// took names only and refused anything followed by `(` - which was the right call
/// given a `SelectSpec` that carried `Array[String]`, and the wrong call given one
/// that carries `Array[Expr]`. The refusal was never the goal; not storing a
/// fragment of syntax in a string and reading it back later was.
fn parse_select_list(p : P) -> Result[(Bool, Array[Expr]), ParseError] {
  if at_punct(p, "*") {
    p.pos = p.pos + 1
    return Ok((true, []))
  }
  let columns : Array[Expr] = []
  while true {
    if at_punct(p, ")") || at_kw(p, "FROM") {
      return Err(
        syntax_here(p, "expected a column, expression or * after SELECT"),
      )
    }
    let e = match parse_expr(p) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    columns.push(e)
    if at_punct(p, ",") {
      p.pos = p.pos + 1
      continue
    }
    break
  }
  Ok((false, columns))
}

///|
/// `SELECT [ DISTINCT ] ( * | <col>... ) FROM <name> [ clauses ]`
///
/// The clauses are read in the order the grammar states and each is stored in
/// its own field. `LIMIT` and `OFFSET` used to be recognised as words in the
/// statement and then never read, so `LIMIT 1` returned every row - which reads
/// as "the table has three rows" rather than as "the limit was ignored".
fn parse_select_stmt(p : P) -> Result[Stmt, ParseError] {
  p.pos = p.pos + 1
  let mut distinct = false
  if at_kw(p, "DISTINCT") {
    distinct = true
    p.pos = p.pos + 1
  }
  let (star, columns) = match parse_select_list(p) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match want_kw(p, "FROM") {
    None => ()
    Some(e) => return Err(e)
  }
  match expect_table(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let mut filter : Expr? = None
  if at_kw(p, "WHERE") {
    p.pos = p.pos + 1
    match parse_expr(p) {
      Ok(v) => filter = Some(v)
      Err(e) => return Err(e)
    }
  }
  let group_by : Array[Expr] = []
  if at_kw(p, "GROUP") {
    p.pos = p.pos + 1
    match want_kw(p, "BY") {
      None => ()
      Some(e) => return Err(e)
    }
    while true {
      let e = match parse_expr(p) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      group_by.push(e)
      if at_punct(p, ",") {
        p.pos = p.pos + 1
        continue
      }
      break
    }
  }
  let order_by : Array[OrderTerm] = []
  if at_kw(p, "ORDER") {
    p.pos = p.pos + 1
    match want_kw(p, "BY") {
      None => ()
      Some(e) => return Err(e)
    }
    while true {
      let t = match parse_order_term(p) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      order_by.push(t)
      if at_punct(p, ",") {
        p.pos = p.pos + 1
        continue
      }
      break
    }
  }
  let mut limit : Expr? = None
  if at_kw(p, "LIMIT") {
    p.pos = p.pos + 1
    match parse_expr(p) {
      Ok(v) => limit = Some(v)
      Err(e) => return Err(e)
    }
  }
  let mut offset : Expr? = None
  if at_kw(p, "OFFSET") {
    p.pos = p.pos + 1
    match parse_expr(p) {
      Ok(v) => offset = Some(v)
      Err(e) => return Err(e)
    }
  }
  let spec = {
    star,
    distinct,
    columns,
    filter,
    group_by,
    order_by,
    limit,
    offset,
  }
  Ok(Select(spec))
}

///|
/// `BEGIN` / `COMMIT` / `ROLLBACK` / `SAVEPOINT` / `RELEASE`.
///
/// A savepoint name is any identifier, and unlike a table name it is not
/// checked: it is a label the client chose, not a table, so there is nothing here
/// that could be the wrong one.
fn parse_txn(p : P) -> Result[Stmt, ParseError] {
  if at_kw(p, "BEGIN") {
    p.pos = p.pos + 1
    if at_kw(p, "TRANSACTION") {
      p.pos = p.pos + 1
    }
    return Ok(Begin)
  }
  if at_kw(p, "COMMIT") {
    p.pos = p.pos + 1
    return Ok(Commit)
  }
  if at_kw(p, "ROLLBACK") {
    p.pos = p.pos + 1
    if at_kw(p, "TO") {
      p.pos = p.pos + 1
      if at_kw(p, "SAVEPOINT") {
        p.pos = p.pos + 1
      }
      let name = match ident_name(p, "expected a savepoint name") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      return Ok(RollbackTo(name))
    }
    return Ok(Rollback)
  }
  if at_kw(p, "SAVEPOINT") {
    p.pos = p.pos + 1
    let name = match ident_name(p, "expected a savepoint name") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    return Ok(Savepoint(name))
  }
  if at_kw(p, "RELEASE") {
    p.pos = p.pos + 1
    if at_kw(p, "SAVEPOINT") {
      p.pos = p.pos + 1
    }
    let name = match ident_name(p, "expected a savepoint name") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    return Ok(Release(name))
  }
  Err(unsupported(p))
}

///|
/// A statement this dialect does not serve.
///
/// A word is one thing and a stray character is another: `DROP TABLE tesseract`
/// is SQL that this build does not implement, and `SELECT * FROM tesseract ?` is
/// a statement with a mistake in it. The first is `UNSUPPORTED_SQL`, the second
/// `INVALID_SYNTAX`.
fn unsupported(p : P) -> ParseError {
  let t = cur(p)
  match t.kind {
    Ident(name) =>
      {
        code: "UNSUPPORTED_SQL",
        message: "unsupported statement `" +
        name +
        "`, this build serves CREATE DATABASE, INSERT, UPDATE, DELETE, SELECT and transaction control",
        at: t.at,
      }
    _ => syntax_at(t, "expected a statement")
  }
}

///|
/// Dispatches on the leading keyword.
fn parse_stmt(p : P) -> Result[Stmt, ParseError] {
  if at_kw(p, "SELECT") {
    return parse_select_stmt(p)
  }
  if at_kw(p, "INSERT") {
    return parse_insert_stmt(p)
  }
  if at_kw(p, "UPDATE") {
    return parse_update_stmt(p)
  }
  if at_kw(p, "DELETE") {
    return parse_delete_stmt(p)
  }
  if at_kw(p, "CREATE") {
    return parse_create(p)
  }
  if at_kw(p, "BEGIN") ||
    at_kw(p, "COMMIT") ||
    at_kw(p, "ROLLBACK") ||
    at_kw(p, "SAVEPOINT") ||
    at_kw(p, "RELEASE") {
    return parse_txn(p)
  }
  Err(unsupported(p))
}

///|
/// Parses one statement.
///
/// One statement per call. The old layer took whatever it was handed and the CLI
/// split scripts on `;` with its own scanner; that scanner is where a `;` inside
/// a quoted value has to be guessed at, and this layer already knows. Callers
/// with a script still split it, and a `;` inside a literal is no longer
/// ambiguous for them either, because a statement that is not finished at its
/// own `;` is an error rather than a silent truncation.
pub fn parse_statement(sql : String) -> Result[Stmt, ParseError] {
  let toks = match lex(sql) {
    Ok(t) => t
    Err(e) => return Err(lex_as_parse_error(e))
  }
  let p = { toks, pos: 0, }
  if at_eof(p) || (at_punct(p, ";") && next_is_eof(p)) {
    return Err({ code: "EMPTY_SQL", message: "empty statement", at: cur(p).at, })
  }
  let stmt = match parse_stmt(p) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if at_punct(p, ";") {
    p.pos = p.pos + 1
  }
  if !at_eof(p) {
    return Err(syntax_here(p, "unexpected token after the statement"))
  }
  Ok(stmt)
}
