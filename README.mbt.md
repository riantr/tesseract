# SudokuDB — 4D (3x3x3x3)

A tiny multi-key JSON value database stored over a **3x3x3x3 sudoku lattice**,
with a SQL surface and sudoku digit constraints.

This is the MoonBit port of the C#/Avalonia `sudokuDB` project, and the C#
project itself has been lifted to the same 4D lattice. The two implementations
were run against the same 26-statement sequence and produce **identical** output —
same success flags, error codes, positions, coordinates and digits.

## The lattice

| | C# original | this version |
|---|---|---|
| shape | flat 9-cell ring shown as 3x3 | 3x3x3x3 lattice, 81 cells |
| addressing | `grid_position` 1..9 | `grid_position` 1..**81**, or `(x,y,z,w)` |
| sudoku | none | digits 1..3, one set per axis-parallel line |
| structure | 9 rows / 1 box | 4 axes x 27 lines = **108 lines**, 12 slabs |

Two numbering schemes coexist deliberately:

- **coordinates** `(x, y, z, w)` are 0-based, matching array indexing;
- **positions** `1..81` are 1-based, matching the C# `grid_position` column, so
  stored SQL and `.sdb` files keep the same shape.

```
position = 1 + x*27 + y*9 + z*3 + w      (row-major, x slowest)
```

The mapping is exact in both directions for all 81 cells.

## What the sudoku constraint is at this size

Worth stating plainly, because the 2D intuition misleads here.

A 2D sudoku has **two** constraint families: 9 rows/columns of 9 cells, and 9
boxes of 3x3. Both draw from one digit domain of 9. Along a 3-long axis the row
rule still works — 3 cells, digits 1..3 — but the box rule degenerates: a box is
only non-trivial when the axis length is at least the digit domain, and at side 3
the only box is the whole grid.

So what survives as a real constraint is the **line family**: 4 axes x 27 lines x
3 cells, each line a permutation of 1, 2, 3. Two cells share such a line exactly
when they agree on three of four coordinates, and each cell has exactly 8 peers.

Slab balance — each digit appearing 9 times in a 27-cell slab — is a **consequence**
of the line rule, not an independent one: a slab is exactly nine lines parallel to
any axis within it, and each contributes one of every digit. The code checks this
rather than assuming it (`slab_violations`), and `solve_lattice` produces solutions
by independent backtracking so the implication is tested on solutions nobody
designed, not only on the closed form.

A closed-form solution exists and is used as the default fill:

```
digit(x,y,z,w) = (x + y + z + w) mod 3 + 1
```

Stepping one cell along any axis adds 1 mod 3, so every axis-parallel line cycles
through all three digits.

## Layout

```
src/sudokudb/
  text.mbt       ASCII helpers: trim, case folding, integer parse, split/join
  coords.mbt     the lattice: coordinates, positions, neighbours, shares_line
  lattice.mbt    lines, slabs, planes, peers
  sudoku.mbt     digits, the line rule, slab balance, backtracking solver
  types.mbt      GridCell, Record, DBResponse, DBStatus, formatting
  logger.mbt     bounded log ring (100 entries, matching the C# logger)
  db.mbt         the 81-cell store
  sql.mbt        the SQL surface
  serialize.mbt  .sdb JSON, .md table, .sql dump, lattice rendering
cmd/main/        command line front end
cmd/gui/         the proton desktop window
  main.mbt       the App: entry point, page asset, command registration
  state.mbt      the store the window drives, and its JSON projections
  commands.mbt   the six typed commands the page can call
  web/index.html the page itself - inline CSS and JS, no build step
proton.project.json   bundle identity, backend package, packaging settings
gui-smoke.mjs         end-to-end smoke test driven through Chromium DevTools
```

The library has **no external dependencies**: the core library in this toolchain
carries no clock, no file I/O and no stdin reader, so what the package needs is
implemented here rather than pulled in. `cmd/main` inherits that.

`cmd/gui` is the one exception, and only because it needs a window: it depends on
`moonbit-community/proton@0.3.4`. Proton is native-only, so that package declares
`supported_targets = "native"` and the rest of the module stays target-agnostic.

## The window

`proton` is Electron-shaped: the page is HTML/CSS/JS, the windows and lifecycle
live in MoonBit, and the two talk over a typed command bridge. The page never
touches the lattice directly — it calls six operations and renders what comes
back, so the store's rules still decide everything:

| operation | what it does |
|---|---|
| `app:state` | occupancy, cursor, digit count, one 3x3 plane, sudoku health, log tail |
| `app:write` | `insert` / `update` / `delete` / `clear` / `cursor`, plus `solve` and `demo` |
| `app:query` | one SQL statement, returning rows and a repaint |
| `app:geometry` | line / slab / peers around a cell, with the covered positions |
| `app:export` | `.sdb`, `.md`, `.sql`, or the ASCII lattice |
| `app:import` | load a `.sdb`, `.md` or `.sql` dump back in |

A digit collision in the window returns the same `SUDOKU_CONFLICT` and the same
message the CLI prints, because it is the same `SudokuDB::insert` call. `solve`
and `demo` run the CLI's `.solve` and `.demo` statement for statement, and the
smoke test pins the end state: after `demo` the store holds 2 records and 1
digit, with `user_002` still at `{"age": 30}` — the same numbers
`moon run cmd/main -- .demo` prints.

Three things the window refuses to do, all because the library's own semantics
would otherwise make a mistyped form destructive:

- **A position outside `1..81` is an error, not "use the cursor."** The page
  omits `position` only when the box is empty; anything the user actually typed
  goes through, so `999` gets `INVALID_POSITION` instead of quietly landing on
  the cursor cell.
- **`delete` needs a key or a position.** With neither, the library means
  "empty the whole lattice", which is what 清空整个点阵 is for; the `delete`
  verb refuses that form with `INVALID_INPUT` rather than wiping 81 cells from
  an empty form.
- **`delete` in the window is cell-scoped.** A bare key is the library's
  "remove every cell carrying it" form, and this button sits in a form framed
  around one cell — so a key with no position (and nothing selected) is refused
  at the page rather than removing rows that are not on screen. Deleting all
  cells by key stays reachable in the SQL console, where the statement says so.

The 清除 digit button is likewise a no-op on a cell that is already empty: it
used to take the insert branch and materialise a `cell_N` record carrying
nothing but the string `0`. And 「无」 in the digit select is sent as an explicit
`digit: 0`, because `update` reads 0 as "drop the digit" — omitting the field
would have kept the old one, so the select and the digit row disagreed about
the same intent.

示例数据巡演 starts with `DELETE FROM sudokuDB;`, so it is marked as destructive
and its button says 「先清空」: it cannot preserve what is already stored.

The page picks one of the nine `(x, y)` planes and shows it as a 3x3 grid over
`(z, w)` — one classic sudoku box, addressed exactly as the library does.

![The SudokuDB window, filled from the closed-form solution](docs-window.png)

Two things about that bridge are worth writing down, because both cost a debugging
round:

- **Optional request fields are omitted, never sent as `null`.** MoonBit's
  decoder for `Int?` accepts a number or no key at all, and treats an explicit
  `null` as a type error. Sending `position: null` fails the whole dispatch with
  `InvalidPayload` before the handler runs.
- **`is_solution` means "no rule is broken", not "every cell is filled."** The
  library's line and slab checks skip empty cells, so a lattice with one hole
  still reads as a solution. The window's chip shows the placed count alongside
  the verdict for exactly that reason.

`solve` runs the closed form through SQL inserts, so it obeys the digit rule like
everything else: filling a partially-filled lattice can legitimately be refused
at some positions. Both surfaces name the first refusal — the window in its
response, the CLI as `placed 80 digits first refused at position 1:
SUDOKU_CONFLICT (Digit 1 already used at position 55)`.

## SQL

The C# statement shapes and error codes still work, so existing dumps load:

```sql
CREATE DATABASE sudokuDB;
INSERT INTO sudokuDB (key, value) VALUES ('user_001', '{"age": 25}');
SELECT * FROM sudokuDB WHERE key = 'user_001';
SELECT * FROM sudokuDB WHERE value LIKE '%age%';
UPDATE sudokuDB SET value = '{"age": 26}' WHERE key = 'user_001';
DELETE FROM sudokuDB WHERE key = 'user_001';
```

The 4D additions:

```sql
-- explicit address, as a position or as coordinates
INSERT INTO sudokuDB (key, value) VALUES ('k', 'v') AT 42;
INSERT INTO sudokuDB (key, value) VALUES ('k', 'v') AT (1,2,0,2);

-- sudoku digits, enforced against the lines through the cell
INSERT INTO sudokuDB (key, value, digit) VALUES ('k', 'v', 2);
UPDATE sudokuDB SET value = 'v', digit = 3 WHERE grid_position = 42;

-- coordinate predicates
SELECT * FROM sudokuDB WHERE x = 1 AND y = 2;
SELECT * FROM sudokuDB WHERE digit = 1;

-- geometry
SELECT * FROM sudokuDB WHERE line(42, 0);   -- the 3-cell axis-parallel line
SELECT * FROM sudokuDB WHERE slab(42, 1);   -- the 27-cell slab
SELECT * FROM sudokuDB WHERE peers(42);     -- the 8 cells sharing a line
```

Every condition in a `WHERE` applies, including alongside a geometry predicate —
`line(42, 0) AND digit = 2` is the digit-2 cell of that line, not the whole line:

```sql
SELECT * FROM sudokuDB WHERE peers(42) AND key = 'user_001';
```

`LIKE` follows the SQL spelling rather than being a substring test: `%x%` is a
contains test and a bare literal is equality. So `value LIKE 'hello'` matches
the value `hello` exactly, and `value LIKE '%hello%'` matches any value
containing it. An unwrapped literal used to be stripped to "no predicate" and
matched every row, which is the direction a filter must not be wrong in.

A malformed literal is an error rather than a value: `WHERE key = 'a` and
`WHERE key = 'a' garbage` both return `INVALID_SYNTAX` instead of quietly
becoming a key that matches nothing. Both `\'` and the standard `''` spell an
embedded quote.

Error codes: `INVALID_INPUT`, `INVALID_DIGIT`, `INVALID_POSITION`,
`INVALID_COLUMNS`, `INVALID_SYNTAX`, `KEY_NOT_FOUND`, `POSITION_NOT_FOUND`,
`POSITION_EMPTY`, `POSITION_OUT_OF_RANGE`, `SUDOKU_CONFLICT`, `UNSUPPORTED_SQL`,
`EMPTY_SQL`. That list is the complete set this port emits — every code in it is
reachable and nothing outside it is produced.

## Running it

### Command line

```sh
moon check --target all     # type-check every backend
moon test                   # 121 tests
moon fmt --check            # canonical formatting

node cli-smoke.mjs          # both CLIs, as real processes (builds them first)
node gui-smoke.mjs          # the window, over CDP (needs `proton_cli dev` running)

moon run cmd/main -- .help
moon run cmd/main -- .status
moon run cmd/main -- .demo
moon run cmd/main -- .solve .verify
moon run cmd/main -- "INSERT INTO sudokuDB (key,value) VALUES ('a','1') AT 5;" "SELECT * FROM sudokuDB;"
moon run cmd/main -- .export sdb > dump.sdb
```

### Persistence

`cmd/persist` is the same store and the same SQL parser with a `.db` file behind
it. It is a **separate binary**, not a flag on `cmd/main`, because
[`moonbit-community/sqlite3`](https://mooncakes.io/docs/moonbit-community/sqlite3@0.2.3)
builds for `native` and `wasm` only — adding it to `cmd/main` or to
`src/sudokudb` would drop those packages from `js` and `wasm-gc` and break the
zero-dependency core. `cmd/main` is untouched, and so is every behaviour in
`src/sudokudb`; the one change to the library is that `SudokuDB::insert_stamped`
is now `pub` rather than private, so this adapter can restore timestamps the way
`import_sdb` already did.

```sh
moon run cmd/persist --target native -- .open sudoku.db \
  "INSERT INTO sudokuDB (key,value,digit) VALUES ('user_001','{\"age\": 25}',1) AT 1;" \
  .save .status .verify

# a second process reads the same file back
moon run cmd/persist --target native -- .open sudoku.db .status
```

| command | effect |
|---|---|
| `.open <path>` | replace the store with the file's contents |
| `.save [path]` | write the store out, to `<path>` or to the last `.open` |
| `.status` | occupancy, digits, cursor, and the file in use |
| `.verify` | line and slab check over the digits in the store |

Everything else runs as SQL through the same parser `cmd/main` uses, so the sudoku
digit rule still decides what happens: an `INSERT` that clashes on a shared line
comes back `SUDOKU_CONFLICT` whether the store came from memory or from a file.

Three things to know before relying on it:

- **It is a snapshot, not a mirror.** The lattice lives in memory between `.open`
  and `.save`; nothing is written back on exit. A session that opens a file and
  never saves says so rather than losing the work quietly.
- **Timestamps round trip.** Each cell is written with its timestamp and loaded
  back through the public `SudokuDB::insert_stamped`, the same call `import_sdb`
  makes, so a reopened `.db` carries the stamps it was saved with instead of ones
  minted from this process's log counter. What does not carry over is the *log*:
  sequence numbers continue from where the new process started, so stamps made
  after a load do not continue the saved file's numbering. **`.sdb` is the format
  when that continuity matters** — `.db` restores what it stored.
- **A load replaces, it does not merge**, the same way `import_sdb` clears first.
  Rows the store refuses — a hand-edited file can hold two cells with the same
  digit on a shared line — are reported as rejected rather than dropped, because
  "loaded 3 of 4" and "loaded 4" are different answers.

The CLI is driven by its **arguments**, one statement or `.command` each, run in
order against one shared database. MoonBit's core library exposes no stdin reader
and no file I/O, so exports go to stdout for the shell to redirect, and a REPL is
a shell loop over the same commands:

A command and its argument are **two arguments**, as a shell splits them —
`.export md` is `.export` and `md`, and the two are rejoined before matching.
`cli-smoke.mjs` covers that, because matching only the joined form is what once
let `.export md` write an `.sdb` document under a `.md` name and `.open` fall
through to the SQL parser as `Unsupported SQL statement: .open`.

```sh
while read -r line; do moon run cmd/main -- "$line"; done
```

### Static analysis

`src/sudokudb_sa` and `cmd/sa` run
[`riantr/moonbit_static_analysis`](https://mooncakes.io/) over this project and
keep the result in a SQLite database, so a scan is queryable history rather than
text that scrolled past.

```sh
moonx riantr/moonbit_static_analysis@0.4.0 . > scan.tsv
moon run cmd/sa --target native -- store scan.tsv scan.db
moon run cmd/sa --target native -- runs scan.db
moon run cmd/sa --target native -- show scan.db
moon run cmd/sa --target native -- files scan.db
moon run cmd/sa --target native -- unparsed scan.db
```

| table | holds |
|---|---|
| `sa_runs` | one row per scan: coverage, counts, target |
| `sa_files` | each file the analyzer reported on, with `outcome`, `defects`, `notices`, `shown` |
| `sa_findings` | the findings that were actually rendered |
| `sa_by_kind` | the per-`.mbt`/`.mbti`/`.mbt.md` rollup the tool prints |
| `sa_unparsed` | per reason: how many files, and up to three example paths |

Runs accumulate, so a 0.3.5 scan and a 0.4.0 scan of the same tree sit in one
file and `runs` prints them side by side. The parser accepts both formats;
refusing the older one would mean a database that can only ever hold scans from
one version of the tool.

Six things to know before reading a number out of it:

- **Quote the coverage, not the finding count.** The analyzer's frontend covers
  a subset of MoonBit, so most `.mbt` files come back unread and their findings
  are *withheld* — they measure what the analyzer does not understand, not what
  your code does wrong. `actionable` is the only column that describes the code.
- **0.4.0 splits every file into three outcomes.** `clean` and `found` mean the
  file was read end to end; `partial` means it was read up to its first parse
  error and nothing after it was looked at. `sa_files.read_up_to` and
  `sa_files.not_shown` keep where that line was. On this project all 12 fully
  read files carry `defects=0` and every actionable finding sits on a partially
  read file — so 30.7% coverage is the honest context for the number 4.
- **Three of the four counters do not describe your code.** `notices` are
  constructs outside the analyzed subset, `unreliable` are findings from a
  partial read, `withheld` are findings on files never read. They are stored in
  their own columns precisely so they cannot be summed into a defect count.
- **The database keeps the truncation visible.** The tool prints at most three
  examples per unparsed reason and only a few findings per file, so
  `sa_files.defects`/`notices` (what the header reported) and `sa_files.shown`
  (what was rendered) are both stored. A list shorter than the count is a
  sample, and the table says so.
- **Withheld findings have nowhere to go on purpose.** There is no column for
  them, because a database that held 1487 rows of them would read as 1487
  problems.
- **A run that did not finish is refused.** The tool exits 0 even when it
  cannot find its target, printing only an `ERROR` line. `parse` treats a
  missing `SUMMARY` as the failure it is, so a failed scan cannot be stored as a
  clean one.

One thing about the tool itself, pinned in the tests rather than corrected here:
0.4.0 labels its `SUMMARY` line `(actionable+notices+unreliable+withheld =
total)`, and that identity does not hold. On this project `4 + 67 + 5122 +
1487 = 6680` against a reported `total` of 5193; the sum that does hold omits
`withheld`. `sa_runs.total` stores what the tool printed rather than a
recomputation.

The counts quoted above come from `src/sudokudb_sa/testdata_scan.tsv`, a
captured run of the tool that is kept frozen so the parser has a fixed input to
be tested against. Re-running the analyzer today gives slightly different
numbers — the tree has changed — and that is expected; refresh the capture with
`_verify/capture.ps1` and update the pinned values in `sa_test.mbt` with it.

`moonx` is invoked separately and its output read from a file, because the tool
is designed so the analysed project neither depends on it nor is modified.

### The window

Pin `proton_cli` to the same version as the `proton` dependency, then install
the CEF runtime once:

```sh
moon update                                        # refresh the registry index
moon install moonbit-community/proton_cli@0.3.4   # match the library version
proton_cli cef setup                               # CEF runtime + subprocess helper

proton_cli doctor                  # identity, toolchain and runtime
proton_cli dev                     # run the window
proton_cli build                   # native build
proton_cli package --dry-run       # check the packaging plan
proton_cli package                 # produce dist/
```

`proton_cli` and the CEF layout it installs are both version-keyed, so a CLI left
on an older version still works — it resolves the same CEF build — but it prints
an upgrade notice on every run. Matching them keeps `doctor` output meaningful.

`proton_cli dev` builds `cmd/gui` for the native target and launches it with the
resource directory pointed at the repository root, so `cmd/gui/web/index.html` is
found relative to that root. Editing the HTML and re-running `dev` is the whole
edit loop; there is no bundler and no generated front end.

Packaged builds resolve the same relative path against `Resources/` beside
`proton-package.json`, so the page has to be declared or the shipped app starts
with nothing to show. That is what `package.resources` in `proton.project.json`
does — each entry is copied to `Resources/<its path relative to the repo root>`,
which lands the page exactly where `@proton.asset` looks for it:

```json
"resources": [ "cmd/gui/web" ]
```

`proton_cli dev` opens a Chromium DevTools endpoint; a packaged build does not,
because debug mode is off by default. Set `SUDOKUDB_DEBUG=1` to get the same
endpoint out of a packaged build — that is how the packaged path is checked with
the same tooling as the dev path.

`gui-smoke.mjs` drives the running window through Chromium's remote-debugging
endpoint — it clicks the real buttons and asserts on what the page renders, so it
covers HTML → bridge → typed command → lattice → JSON reply, not just that the
binary starts:

```sh
node gui-smoke.mjs
```

## Export formats

| format | role |
|---|---|
| `.sdb` | JSON, the native save format; round-trips key, value, position, digit and timestamp losslessly |
| `.md` | Markdown table, human-readable and diffable |
| `.sql` | SQL dump this package's own parser re-imports |

The C# exporter's `.sql` dialect still loads: backticked `` `key` `` / `` `value` ``
quoting is stripped and a `timestamp` column is accepted and ignored.

## Deliberate departures from the C# original

Each of these is a behaviour change, so each is deliberate:

1. **The grid is 81 cells, not 9**, and is addressable by coordinate.
2. **`current_count` is computed from occupancy**, not accumulated. The C# counter
   saturated at 9 on the first wrap and then only decremented, so it drifted away
   from the number of stored records; reporting the real occupancy is what
   `GetStatus` was always asking for.
3. **A malformed address never resolves to another cell.** Out-of-range positions
   and unparseable coordinates are errors, not clamped values — a silent clamp
   would write to a cell the caller never asked for.
4. **Out-of-range positions give a clean error code** instead of the C#
   `KeyNotFoundException` surfacing as a generic failure. Which code depends on
   the verb, and the split is deliberate: `POSITION_OUT_OF_RANGE` for the verbs
   that address an existing record (`update`, `delete`, the geometry queries),
   and `INVALID_POSITION` for `INSERT`, whose position names a target to write
   rather than a record to find.
5. **No wall clock.** MoonBit's core library has no clock and reaching for one
   would pin the package to a single target, so log stamps are a logical sequence
   number. That also makes log output deterministic under test.
6. **There is a window, and it is not Avalonia.** The C# original was Avalonia;
   this is a [proton](https://moonbit-community.github.io/proton/) app — the same
   HTML/CSS page surface and native-window model, rebuilt on a different runtime.
   The CLI is still there and still shares the library.
7. **The store lives in memory, and so does the window's copy of it.** The C# app
   had the same in-memory model; there is no file backing either, so closing the
   window discards what is in it. The export formats are the way out — and, if
   you want a file that a SQL engine can read, `cmd/persist` below.

Three format caveats: the Markdown table writes newlines as `<br>`, so a value
containing that literal text comes back as a newline — `.sdb` is the lossless
format. The SQL dump escapes `\n`, `\r`, `\t`, `\'` and `\\`, matching what
the parser reverses. And the Markdown table escapes TAB and CR as `\t` and
`\r` rather than reformatting them, which is why all three formats round-trip
these values.

Timestamps are restored by `.sdb` and by the `.db` adapter below, both of which
reinsert through `SudokuDB::insert_stamped`. The other two formats do not:
`import_markdown` re-stamps from the log counter, and `import_sql` ignores the
column — so `.md` exports carry a timestamp column that its own importer throws
away, and `.sql` carries none. Use `.sdb` or `.db` when the stamps matter.

An import replaces the store rather than merging into it, so a failed load
leaves an empty database instead of a half-overwritten one, and a record with
no usable address is refused by name rather than being written to cell 1.
