# LOOP 2 — wall clock, transactions, and a real SQL engine

`LOOP.md` recorded turning `SIDE` into a value. This one records the three things
that were listed as *not done* in that document's closing section:

- no wall clock — "MoonBit's core library has no clock"
- no concurrency or transactions
- the SQL surface is a hand-rolled subset, not an engine

All three are now in scope. This file is the plan and the record; the measured
numbers below are the acceptance criteria.

---

## What the baseline actually is

Measured against `c95383c` plus the uncommitted `side` work, using the real CLI.
Every number here came out of a run, not out of reading the source.

### The clock premise is false

`README.mbt.md` and `logger.mbt` both say the toolchain has no clock. It has one,
in **core**, on every target the module claims to support:

| target | implementation | source |
|---|---|---|
| native | `moonbit_get_ms_since_epoch` | `$MOON/lib/core/env/env_native.mbt` |
| js | `Date.now()` | `$MOON/lib/core/env/env_js.mbt` |
| wasm / wasm-gc | `__moonbit_time_unstable` `now` | `$MOON/lib/core/env/env_wasm.mbt` |

`@env.now() -> UInt64`, **milliseconds since the Unix epoch on all three**. So a
real clock does not have to pin the package to a single target, and it costs no
dependency: `moonbitlang/core` is the toolchain, not a mooncakes import, so
`src/tesseract` stays dependency-free.

The original reason for refusing was target-portability plus determinism under
test. Portability turns out not to apply. Determinism still does, so the clock is
**injected** rather than called inline: production surfaces wire the system clock,
tests wire a counter.

### The SQL surface is not an engine, and two of its failures are silent

Five probes through `moon run cmd/main`, with the store holding `alpha@1`, `beta@2`
(so `WHERE key='alpha' AND key='beta'` is the interesting case):

| statement | measured | correct SQL |
|---|---|---|
| `WHERE key='alpha' AND key='beta'` | **1 row, `beta`** | 0 rows |
| `WHERE key='alpha' OR key='beta'` | `INVALID_SYNTAX` | 1 row |
| `SELECT * FROM tesseract LIMIT 1` | **3 rows** | 1 row |
| `SELECT * ... ORDER BY key DESC` | `zulu, alpha, mike` (insertion order) | `mike, alpha, zulu` |
| `WHERE digit=1+1` | `INVALID_SYNTAX` | digit 2 |

Two of those are the bad kind. `LIMIT 1` and `ORDER BY` do not fail — they are
**parsed as nothing and silently dropped**, so the query answers a different
question than the one asked and reports success. `AND` is not a conjunction:
`parse_where` threads one `Where` struct through `split_keyword(body, "AND")`,
and every `with_*` helper **overwrites** its field, so the last conjunct wins and
the earlier ones vanish.

The root cause is the shape. `sql.mbt` is 932 lines of repeated string scanning —
`find_word`, `split_top_level`, `split_keyword`, `index_of_ci` — and `Where` is a
struct of at most one predicate per field:

```moonbit
pub struct Where {
  key : String
  pattern : String
  position : Int64?
  ...
}
```

There is nowhere to put a second `key` predicate, so a conjunction over the same
column cannot be represented, let alone evaluated. Fixing this without an
expression tree is not possible; the struct has to be replaced by a tree.

### What the transaction layer does not need to fix

Single-statement atomicity already holds. Inserting `p2` with a digit already used
by `p1` on a shared line returns `SUDOKU_CONFLICT` **and leaves the target cell
holding its previous record** — verified by selecting that position afterwards.
So the work is cross-statement atomicity and a rollback point, not "stop writing
half a row".

### On concurrency, stated honestly

MoonBit has no data races here to fix: one process, cooperative async, no shared
mutable memory between tasks except through this store. What is worth delivering
is **serializability by construction** — a writer is the only writer, and its unit
of atomicity is the statement, or the transaction when one is open. The GUI already
holds one `@async.Mutex` around every bridge handler; that lock is the isolation
boundary, and the journal below is the atomicity mechanism. Neither replaces the
other, and this document will not claim thread-safety the runtime does not have.

---

## The six steps

### Step 1 — a real clock, injected

`src/tesseract/clock.mbt`:

```
pub enum Clock { Logical; System; Fixed(UInt64) }
pub fn Clock::stamp(self, seq) -> String
```

The logger already owns a sequence number, so the clock only has to decide *what
kind* of stamp that number becomes:

- `Logical` → `"#7"`, unchanged, and what tests use
- `System` → `2026-10-16T19:45:00.123Z` from `@env.now()`
- `Fixed(ms)` → the same rendering, from a frozen instant, so the ISO formatting is
  testable without a real clock

Civil-date conversion is written here rather than pulled from `moonbitlang/x/time`,
because `x` is an external dependency and the core library's zero-dependency
property is a deliberate, tested claim.

`GridCell.timestamp` and `Record.timestamp` are **already `String`** — the CLI
prints `时间: 0`, which is the string `"0"`. So this changes the content of a
stamp, not its type, and every existing `.tsr` written by the old logger still
imports unchanged.

Gate: an ISO round trip over a known instant, a `Fixed` clock producing exactly
that string, and `Logical` still producing `#7`.

### Step 2 — a lexer

`src/tesseract/lexer.mbt`. Tokens carry a byte offset so a parse error can name
where it happened instead of only what it was. Handles identifiers, keywords,
integer literals, single-quoted strings with both `''` and `\'` escapes,
punctuation, the two-character comparison operators, `--` line comments and
`/* */` block comments.

### Step 3 — AST and parser

`src/tesseract/ast.mbt`, `src/tesseract/parser.mbt`. Recursive descent, with
precedence climbing for expressions:

```
OR  <  AND  <  NOT  <  comparison  <  additive  <  multiplicative  <  unary  <  primary
```

covering `= <> != < <= > >= LIKE IN IS NULL AND OR NOT`, `+ - * / %`, parentheses,
function calls, and the three geometry predicates `line(pos, axis)`,
`slab(pos, axis)`, `peers(pos)`.

Clauses: `SELECT` with an explicit column list, `WHERE`, `GROUP BY`,
`ORDER BY` with per-term `ASC`/`DESC`, `LIMIT`/`OFFSET`, aggregate functions
(`count`, `sum`, `min`, `max`, `avg`); `INSERT`/`UPDATE`/`DELETE` with
`AT position` and `AT (x,y,z,w)`; `CREATE DATABASE`; and the transaction
statements `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT name`, `ROLLBACK TO name`,
`RELEASE name`.

### Step 4 — the transaction engine

`src/tesseract/txn.mbt`. An undo journal of before-images, not a snapshot, so a
transaction costs what it wrote rather than what the lattice holds.

- every statement opens an implicit savepoint and drops it on failure, so a
  statement that fails halfway leaves nothing behind
- `BEGIN` opens an explicit one; `COMMIT` discards the journal; `ROLLBACK` replays
  it backwards
- nested `BEGIN` is `INVALID_INPUT`, because `SAVEPOINT` is the supported nesting
  story and a silently nested transaction is worse than a refusal

### Step 5 — the executor

`src/tesseract/exec.mbt`, replacing the string scanner in `sql.mbt`. Walks the AST,
evaluates the expression tree against each `Record`, and **raises on any clause it
does not implement**. The rule that comes out of the silent-`LIMIT` measurement:
a parser that accepted a clause must either apply it or refuse the statement.

### Step 6 — the gates

A regression test per measured defect, each stating the wrong answer it replaces:

| gate | replaces |
|---|---|
| `AND over one column is a conjunction` | returned `beta` |
| `OR is a disjunction` | `INVALID_SYNTAX` |
| `LIMIT bounds the rows returned` | returned 3 rows for `LIMIT 1` |
| `ORDER BY actually orders` | returned insertion order |
| `an integer expression evaluates` | `INVALID_SYNTAX` on `digit=1+1` |
| `a rolled-back transaction changes nothing` | no rollback existed |
| `a failed statement leaves no partial write` | pins what already worked |
| `a fixed clock formats a known instant` | pins ISO output without a clock |

Plus the standing gates: `fmt --check`, `check`, `check --target native`,
`moon test`, `cli-smoke.mjs`, `gui-smoke.mjs`.

---

## Record — step 1, the clock

Done, and the plan above needed three corrections that only measurement could
have produced.

**The clock was available all along, in `core`.** `@env.now()` resolves and
compiles for native, js and wasm after adding one line to `src/tesseract/moon.pkg`:

```
  "moonbitlang/core/env",
```

`core` is the toolchain, not a mooncakes import, so the zero-dependency claim on
`src/tesseract` survives. What did not survive was the stated reason.

**`UInt64` and `Int64` are the same bit pattern with different literal suffixes,
and there is no numeric conversion between them.** Measured, all four of these:

| attempt | result |
|---|---|
| `x.to_int64()` | compiles, deprecated → use `reinterpret_as_int64` |
| `Int64::from_uint64(x)` | `4015` — no such method |
| `(x : Int64)` | `4014` — no implicit coercion |
| `@env.now()` | compiles |

**Enum variants are not constructible from another package.** A blackbox test
writing `@tesseract.Clock::Logical` gets `Cannot create values of the read-only
type: Logical` — and so does the bare `@tesseract.Logical` spelling. Adding `pub`
to a variant is separately refused with `No individual visibility for enum
constructor`. So the three ways to make a clock are now functions
(`logical_clock`, `system_clock`, `fixed_clock`) and the variants stay private to
the package. `Clock` also derives no `Eq`, so a test compares the *string* a clock
produces, never the clock.

**The cell timestamp did not go through the logger's stamp at all.** `db.mbt` was
writing `db.logger.seq.to_string()` directly, which is why a record shows
`时间: 0` while its log line shows `[#1]`. Both now go through the clock, and
there are two methods on purpose:

- `Clock::stamp(seq)` → `#7` or ISO, the label a person reads off the console
- `Clock::cell_stamp(seq)` → `7` or ISO, the data that goes into `.tsr`/`.md`/`.sql`

The sigil difference is the only difference, and it is deliberate: `GridCell
.timestamp` is a `String` already, so this changes the *content* of a stamp and not
its type, and every `.tsr` written by the old logger still imports.

Measured end to end through the real CLI:

```
[2026-10-16T12:02:35.887Z] [INFO] INSERT succeeded      ← stderr, wall clock
  时间: 2026-10-16T12:02:35.886Z                          ← cell, wall clock
{"grid_position": 1, ..., "timestamp": "2026-10-16T12:02:36.270Z"}   ← still a JSON string
```

`12:02 UTC` is `20:02` local, which is when the run actually happened.

**A smoke assertion was silently comparing the wrong thing.** `cli-smoke.mjs`
extracted stamps with `时间:\s*(\d+)`, which under the wall clock captures
`2026` — the year — so two stamps written a second apart compared **equal**, and
"a reopened cell keeps the stamp the file was saved with" was passing for the
wrong reason. It is now `(\S+)` plus an explicit ISO-versus-counter comparison,
because `Number()` is wrong for both regimes in different ways (`NaN` for ISO, and
the old regex was handing it a bare year). 14/14 pass.

Gates after step 1: `fmt` 0, `check` 0, `check --target native` 0,
`moon test` **145 passed / 0 failed** (was 136; nine clock tests added).

---

## Record — steps 2 to 5, the engine

Done. `sql.mbt` is **deleted**, not rewritten: its 932 lines of string scanning
are replaced by `lexer.mbt` (373), `ast.mbt` (159), `parser.mbt` (1173) and
`exec.mbt`. The rule that came out of the silent-`LIMIT` measurement is the one the
executor is built around:

> **A clause the parser accepts is a clause the executor applies, or the statement
> is refused.**

The five defects, re-measured through the real CLI after the change:

| statement | before | after |
|---|---|---|
| `WHERE key='alpha' AND key='mike'` | 1 row, `beta` | `查询结果 (0 条记录)` |
| `WHERE key='alpha' OR key='mike'` | `INVALID_SYNTAX` | 2 rows |
| `SELECT ... LIMIT 1` | **3 rows** | 1 row |
| `SELECT ... ORDER BY key DESC` | **insertion order** | `zulu, mike, alpha` |
| `WHERE digit=1+1` | `INVALID_SYNTAX` | evaluates |

### Six bugs the work surfaced, five of them mine

**1. The contract was wrong, and the subagent was right about it.** `SelectSpec
.columns` was specified as `Array[String]`, which is why the parser refused
`SELECT count(*)` — storing it as the text `"count(*)"` and reading it back later is
the exact "accept the clause, then mean something else by it" failure the layer
exists to prevent. The refusal was correct given the contract and the contract was
the problem. `columns` is now `Array[Expr]`.

**2. `INSERT` without `AT` stopped advancing the cursor.** I resolved "no target"
to the cursor's *position*, which looks equivalent and is not: `Tesseract::insert`
reads a missing target as *follow the cursor and advance it*. Every un-targeted
`INSERT` landed on the same cell and overwrote the row before it. Two statements of
the C# demo sequence stopped being two records, and a generated 12-row dataset
came out as 1.

**3. `peers(pos)` included `pos`.** `shares_line(c, c)` is trivially true, so
`WHERE peers(1)` returned the row at position 1 along with its eight line-mates.

**4. An expression was only evaluated when there were rows.** `SELECT * FROM t
WHERE bogus = 'x'` on an empty table **succeeded with zero rows**, because a filter
is evaluated against rows and there were none. So an unknown column was accepted on
an empty table and refused on a full one. Same for `UPDATE ... SET bogus`, whose
column list was never checked when nothing matched. Both now evaluate once against
a synthetic row and refuse what they cannot answer — *whether the table has data is
not a fact that decides whether a statement is well formed.*

**5. The select list dropped everything that was not a plain column.**
`SELECT length(key) FROM tesseract` returned a row whose `value` was the
underlying record's value and said nothing about the function. `Record` is a fixed
shape, so non-column items go into a new `computed : Array[Computed]` field carrying
the label they were written under — a result a caller has to label by position is a
result they cannot read.

**6. `DISTINCT` compared whole records.** Three cells holding the same value stayed
three rows, because `key` and `position` differ. Projection now empties `position`
and `coords` when they were not selected, so the comparison is over what was asked
for.

### What the old behaviour lost, and why

Four `sql_test.mbt` assertions pinned behaviour that is now gone. Each is recorded
rather than quietly rewritten:

- `LIKE ''` is no longer a syntax error. It is a pattern that matches nothing, which
  is what it says. The failure that actually mattered — an unwrapped literal
  becoming "every row" — is still pinned.
- `AT (9,9,9,9)` is `INVALID_POSITION` naming the coordinate, not `INVALID_SYNTAX`.
  The parser has no lattice; the executor does, and the cell was the problem.
- An unknown column is `INVALID_COLUMNS`, the code the project already uses for "a
  column that is not in the schema".
- `UPDATE ... SET digit = 2` now works on its own. The old parser only knew how to
  rewrite a value, so setting a digit required also setting a value you may not have
  wanted to change.

And two places where a test of mine was the thing that was wrong, both the same
shape: positions 1 and 2 differ only in `w`, so they share a line and cannot both
carry one digit. A fixture that put digit 1 on each of them had its second insert
refused with `SUDOKU_CONFLICT`, and the aggregate then summed two rows instead of
three — which read as an arithmetic bug and was a bug in the test.

### Gates after step 5

```
fmt 0   check 0   check --target native 0
moon test   220 passed / 0 failed   (was 136 before this LOOP)
cli-smoke.mjs   14 PASS / 0 FAIL
```

`exec_test.mbt` holds one test per measured defect, and each names the answer the
old surface gave. A test asserting only the new answer would pass just as happily
if the old wrong answer had never been wrong, and nobody reading it later would
know what it protects.

---

## What this deliberately does not do

- **Not SQLite, and not trying to be.** No file format compatibility, no indexing
  strategy, no query planner. One table, one row type, a full expression
  evaluator. The claim is "a real parser and executor", not "SQL-standard".
- **Not thread-safe, because the runtime is not.** Serializability comes from
  being the only writer; the journal makes the unit of atomicity explicit.
- **Not a replacement for `cmd/persist`.** That adapter stores a snapshot through
  sqlite3 and stays a separate binary. It will gain transaction awareness, but it
  does not become the engine.
- **`x/time` stays out.** The date arithmetic is ~40 lines and a test fixture; a
  dependency would cost more than the code.
