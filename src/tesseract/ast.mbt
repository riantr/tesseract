///|
/// The parsed shape of a statement, and the grammar in brief.
///
/// Every node here is what the statement *says*, with nothing resolved. The
/// parser has no lattice, no column schema and no function table, so a `Column`
/// is a name and a `Call` is a name plus arguments; deciding what either means
/// belongs to the executor, which owns all three.
///
/// Two properties are deliberate and worth stating once:
///
/// - **`Binary("AND", a, b)` nests instead of flattening.** The old `Where` was
///   a struct with at most one predicate per field, so `WHERE key = 'alpha' AND
///   key = 'beta'` could not be *written* down - the second conjunct overwrote the
///   first and the query answered a different question than it was asked. A tree
///   has no such limit, and the shape of the tree is the shape of the question.
/// - **Every operator the parser accepts, the AST can represent.** A clause that
///   parses is a clause the executor can see. The one thing refused outright is
///   anything that would have to be dropped to fit a node - see `SelectSpec`.

///|
/// A literal written in the statement.
pub enum SqlValue {
  Null
  Int(Int64)
  Text(String)
} derive(Eq, Debug)

///|
pub extend SqlValue with Eq::{equal, not_equal}

///|
pub extend SqlValue with @debug.Debug::{to_repr}

///|
/// An expression node.
///
/// `AND` and `OR` carry their operator as a canonical uppercase string rather
/// than as separate constructors. Two constructors for one operator would let
/// the parser spell the same node two ways, and an executor that pattern-matches
/// has to remember to handle both - the failure being that one spelling quietly
/// matches nothing.
pub enum Expr {
  Literal(SqlValue)
  Column(String)
  Not(Expr)
  Neg(Expr)
  Binary(String, Expr, Expr)
  Like(Expr, Expr)
  In(Expr, Array[Expr])
  IsNull(Expr, Bool)
  Call(String, Array[Expr])
  Star
} derive(Eq, Debug)

///|
pub extend Expr with Eq::{equal, not_equal}

///|
pub extend Expr with @debug.Debug::{to_repr}

///|
/// Where an `INSERT` puts its row.
///
/// `None` is not "position 0": it means the statement named no target, and the
/// cursor decides. The old parser resolved `AT (x,y,z,w)` against a lattice it
/// had to be handed, so the same statement meant different cells under different
/// sides; carrying the four coordinates leaves that decision where the lattice
/// is known.
pub enum Target {
  None
  Position(Int64)
  Coords(Array[Int64])
} derive(Eq, Debug)

///|
pub extend Target with Eq::{equal, not_equal}

///|
pub extend Target with @debug.Debug::{to_repr}

///|
/// One `column = expr` pair of an `UPDATE ... SET` list.
pub struct Assignment {
  column : String
  value : Expr
} derive(Eq, Debug)

///|
pub extend Assignment with Eq::{equal, not_equal}

///|
pub extend Assignment with @debug.Debug::{to_repr}

///|
/// One `ORDER BY` term and its direction.
///
/// `ASC` is recorded as `descending = false` rather than as a separate spelling,
/// so a term with no direction and a term written `ASC` are the same node.
pub struct OrderTerm {
  expr : Expr
  descending : Bool
} derive(Eq, Debug)

///|
pub extend OrderTerm with Eq::{equal, not_equal}

///|
pub extend OrderTerm with @debug.Debug::{to_repr}

///|
/// A `SELECT` and every clause written on it.
///
/// `star` and `columns` do not overlap: `SELECT *` sets `star` and leaves
/// `columns` empty. `filter`, `limit` and `offset` are `None` when the clause is
/// absent, which is different from a clause that was present and evaluated to
/// nothing - `LIMIT 0` is `Some(Literal(Int 0))` and answers no rows.
///
/// The select list holds expressions, not names. It held `Array[String]` at first,
/// and that was a mistake in the *contract* rather than in the parser: with
/// strings there was nowhere to put `count(*)` short of storing the text
/// `"count(*)"` and reading it back later, which is precisely the "accept the
/// clause, then mean something else by it" failure this file exists to prevent -
/// so `parse_select_list` refused it. Holding `Expr` removes the temptation.
pub struct SelectSpec {
  star : Bool
  distinct : Bool
  columns : Array[Expr]
  filter : Expr?
  group_by : Array[Expr]
  order_by : Array[OrderTerm]
  limit : Expr?
  offset : Expr?
} derive(Eq, Debug)

///|
pub extend SelectSpec with Eq::{equal, not_equal}

///|
pub extend SelectSpec with @debug.Debug::{to_repr}

///|
/// A whole statement.
pub enum Stmt {
  CreateDatabase(String)
  Insert(Array[String], Array[Expr], Target)
  Update(Array[Assignment], Expr?)
  Delete(Expr?)
  Select(SelectSpec)
  Begin
  Commit
  Rollback
  Savepoint(String)
  RollbackTo(String)
  Release(String)
} derive(Eq, Debug)

///|
pub extend Stmt with Eq::{equal, not_equal}

///|
pub extend Stmt with @debug.Debug::{to_repr}
