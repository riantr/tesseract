# LOOP — making `SIDE` a variable

Status: all five steps implemented. The library no longer has a `SIDE`
constant — `lattice_of(side)` builds the shape, `Tesseract` carries it, and
positions are `Int64`. The CLI takes `--side N` / `--side=N`, and the window has
a side selector.

`moon check`, `moon check --target native`, `moon fmt --check` and `moon test`
all exit 0, and both `cli-smoke.mjs` and `gui-smoke.mjs` pass.

What is **not** done, and is deliberately not claimed:

- **The ceiling is still 215**, for the storage reason measured below. Nothing
  here changes that; lifting it needs storage that is not one flat array.
- **No cross-format side selection.** `cmd/persist` takes its shape from the
  database it opens; it has no `--side` of its own.
- **The window's selector offers sides 1..9**, not all 215 legal ones: a
  side-of-9 lattice is 6561 cells and a window is not drawing that. The backend
  accepts the full range through SQL and the CLI.

`SIDE` is currently a compile-time constant (`3`) baked into 97 sites across 13
files. This document is the plan to turn it into a value chosen at construction
time, and the measurements that bound that plan.

## The shape of the thing

The lattice is fixed at four axes. What varies is how many cells each axis has.
Everything else follows:

| quantity        | now   | as a function of `side` |
| --------------- | ----- | ------------------------ |
| cells           | 81    | `side^4`                 |
| digits          | 1..3  | `1..side`                |
| lines           | 108   | `4 * side^3`             |
| slabs           | 12    | `4 * side`               |
| cells per slab  | 27    | `side^3`                 |
| peers per cell  | 8     | `4 * (side - 1)`         |

The sudoku rule survives for free: `digit(x,y,z,w) = (x+y+z+w) mod side + 1`
steps by 1 along any axis, so every axis-parallel line is a permutation of
`1..side`. No sudoku code has to change shape — only its `SIDE` reference.

## What was measured before planning

Three probes, run against this toolchain, then deleted. The numbers below are
output, not arithmetic done in my head.

**1. The Int64 ceiling is 55,108, not 46,340.** `46,340` appeared in an earlier
draft of this plan and was wrong: it is `floor(sqrt(Int32::MAX))`, a *square*
root bound, offered where a *fourth* root was needed.

```
max side with side^4 <= Int64::MAX  = 55108
  side^4 there   = 9222710978872688896
max side with side^4 <= Int32::MAX  = 215
```

**2. `Int` is 32-bit here, so a flat array caps `side` at 215 regardless.**
Indexing an `Array` with an `Int64` is a type error, not a conversion:

```
let a = [10, 20, 30]
let i : Int64 = 1
let x = a[i]
             ^
Expr Type Mismatch
    has type : Int64
    wanted   : Int
```

and on the default (wasm) target the literal check confirms the width:

```
let b : Int = 2147483648
              ^
Integer literal 2147483648 is out of range.
```

So moving position arithmetic to `Int64` is right for the *type system* and
does **not** by itself raise the ceiling. Lifting the ceiling past 215 needs the
storage container to stop being one flat `Array` indexed by `Int` — a separate
piece of work, recorded here as the known limit rather than smuggled in.

**3. A position number does not survive a side change.** Among positions `1..81`,
the fraction that address a *different* cell once the side goes 3 → 4:

```
positions 1..81 whose CELL changes when side goes 3 -> 4
  moved = 78 / 81
  p=40 side3 first coord = 1, side4 first coord = 0
  p=40 side3 last coord  = 0, side4 last coord  = 3
```

This is why import remaps by coordinate rather than by position number, and
why the `.tsr` format already carries `"side"` and per-record `"coords"`.

## The five steps

Each step ends green. The order is chosen so the riskiest change — turning
`index0`/`coords_of` from literals into arithmetic — lands while nothing else is
moving yet, and is proved byte-identical at `side == 3` before anything flips.

### Step 1 — `Lattice` as a value, positions as `Int64`

Introduce `Lattice { side, dim, total, first_position, last_position, max_digit }`
built by `lattice_of(side)`, which rejects `side < 1` and reports the 215
addressability limit rather than trapping.

Generalise the two hardcoded functions:

- `index0(c) = x*27 + y*9 + z*3 + w` becomes `x*side^3 + y*side^2 + z*side + w`,
  computed in `Int64`.
- `coords_of(p) = coords(p/27, p/9%3, p/3%3, p%3)` becomes the inverse
  division chain by `side`.

`coords_in_bounds`, `position_in_bounds`, `parse_coords`, `all_coords` follow.
`SIDE`/`TOTAL`/`LAST_POSITION`/`MAX_DIGIT` survive as `DEFAULT_LATTICE` so the
default stays byte-identical.

**Gate:** the existing suite passes with no assertion edited. A `side=3` sweep
asserts `index0`/`coords_of` are exact inverses over all 81 cells.

### Step 2 — `lattice.mbt` and `sudoku.mbt` take the lattice

`line_through`, `slab_through`, `plane_through`, `all_lines`, `all_slabs`,
`neighbours`, `peers`, `peer_count`, `shares_line`, `free_axis_of` gain a
lattice argument.

Two latent assumptions break the moment `side > 3` and must be fixed here, not
later:

- `sudoku.mbt` allocates `let counts = [0, 0, 0, 0]` and indexes it by digit.
  At `side == 4` the digit domain is `1..4`, so `counts[4]` is out of bounds.
  The tally becomes `max_digit + 1` long.
- `free_axis_of` compares only `line[0]`, `line[1]`, `line[2]`. On a 4-cell line
  the fourth cell is never examined. It happens to return the right axis at
  `side == 4`, but by accident rather than by construction; it scans every cell.

**Gate:** a sweep over `side ∈ {1, 2, 3, 4, 5}` asserting every line is a
permutation of `1..side`, every full slab holds each digit `side^3 / side` times,
and `canonical_digits` reports zero violations at every side.

### Step 3 — the store carries its lattice

`Tesseract` gains a `lattice` field; `new_db(name, side, logger)` builds it.
`GridCell.position`, `Record.position`, `DBResponse.position`,
`DBStatus.total_cells` and `current_position` become `Int64`. Digit validation
(`digit < NO_DIGIT || digit > MAX_DIGIT`) reads `lattice.max_digit`.

**Gate:** the existing `db_test.mbt` passes against the default lattice, plus a
`side=4` case exercising 256 cells, cursor wraparound, and digit rejection at 4.

### Step 4 — serialisation: real header, coordinate-remapped import

`export_tsr` writes the database's own `side`/`dimensions`/`total_cells` instead
of the literals `4`/`3`/`81`. `render_lattice` draws from the lattice; at
`side == 4` it is 16 blocks of 16 cells and the existing fixed-width layout needs
a second look before it is honest.

`import_tsr` reads the source `side` and each record's `coords`, builds the source
lattice, and maps each record to `index0(target_lattice, coords)` in the target.
A coordinate outside the target lattice, or a `dimensions` mismatch, is an error
— never a silent clamp.

**Gate:** a `side=3` file imported into a `side=4` database lands on the cells its
coordinates name, checked cell by cell against an independently computed table.
A file declaring `side=4` with a `side=3` coordinate is rejected with the offending
coordinate named.

### Step 5 — the `side` surface, a sweep gate, and honest documentation

Done, except for the window's side picker.

`cmd/main` takes `--side N` and `--side=N`. The option may sit anywhere among the
commands, only the first occurrence counts, and both spellings consume their own
argument — the first version set the value from `--side=N` and then ran the flag
itself as SQL, so the run reported `Unsupported SQL statement: --side=3` after
having already built the database at the right side. A repeated flag is consumed
and ignored for the same reason. A value that is not an integer, is below 1, or
is above 215 is refused before any statement runs, so a bad flag cannot leave a
half-built database behind. Omitting it gives side 3 and unchanged behaviour.

`cmd/gui` has a side selector next to the plane pickers. It is not a second
implementation of the resize: it calls `Tesseract::set_side`, and the page rebuilds
every shape-dependent list from the `side` on each snapshot.

### What the side selector needed that the plan did not have

**The store could not be replaced, only resized.** The obvious design — build a
new `Tesseract` and swap it in — is refused by the compiler:

```
db = @tesseract.new_db(...)
  ^
  The variable db is not mutable.
```

A top-level `let` is a mutable *place* (which is why `mut current_position`
persists through the store), but the binding itself cannot be rebound. Holding
the store in an `Array` element does not help: reading `store[0]` copies the
struct, and the copy takes its `mut current_position` with it. Measured — a
cyclic insert through `store[0]` left the cursor at 1 instead of advancing to 2.

So the store is resized **in place**: `lattice` and `cells` became `mut` fields
and `Tesseract::set_side` rebuilds them, carrying records over by coordinate for
the same reason the importer places them that way. A record whose coordinates
still fit lands on the same cell; one that cannot fit is dropped and counted in
`ResizeReport::dropped` rather than clamped onto a cell nobody put it in.

**The page had six literal `3`s**, not one: the axis pickers, the digit `<select>`
options, the digit swatch buttons, the grid's `grid-template-columns`, the header
line, and the geometry labels ("线 (3 格)"). A selector that only changed the grid
would have passed a test that looked at the grid, so `gui-smoke.mjs` now checks
all six at side 4 and checks the resize back to 3. The digit swatches needed CSS
for `.d4`…`.d9` as well: a digit 4 rendered with no colour at all, because its
class was `d4` and no rule claimed it.

**Widening cannot introduce a digit-rule conflict, and that is structural.**
Carrying a solved side-3 lattice to side 4 gives 81 digits in 256 cells — not 256.
Every side-3 coordinate lies inside a side-4 lattice, so all 81 records survive and
the 175 newly reachable cells are simply blank. Two cells share an axis-parallel line
when their coordinates agree in all but one axis, which is a property of the
coordinates and not of `side`; widening only appends *blank* cells to each line and
never changes which filled cells share one. Both checkers skip `NO_DIGIT`, so a wider
lattice cannot manufacture a violation the narrower one did not already have.

The price is wording. On 81 digits out of 256, `is_solution` means "no violation so
far" — both `line_violations` and `slab_violations` skip empty cells, and
`slab_violations` only inspects slabs that are completely full. So the window's badge
reads 数位规则无冲突（81/256）, not 完整解, and `gui-smoke.mjs` now asserts both halves:
the positive text *and* the absence of 完整解, so the window cannot start over-claiming
a complete solution without the test failing. `db_test.mbt` measures the same fact
against the library, and guards it: the test counts the digits it read back out of
the store and requires 81, because an all-empty `carried` has no line that can repeat
a digit and no full slab — both checkers would report nothing and the test would pass
on a resize that dropped every digit.

Standing gates added, all of which fail loudly rather than passing vacuously:

| gate | what it pins |
|---|---|
| `line and slab counts follow the side, not a constant` | counts at `side ∈ {1,2,3,4}` |
| `the closed form is a solution at every side from 1 to 4` | 0 line violations, 0 slab imbalances |
| `a side-3 file ... lands on its coordinates, not its position number` | the cross-side import rule, with the negative half |
| `78 of the 81 side-3 positions name a different cell at side 4` | the scale of the trap, as a number |
| `a coordinate outside the target lattice is refused and named` | no silent clamp |
| `a carried-over side-3 solution is measured against the side-4 rule` | the widening claim above, plus the 81-digit non-vacuity count |
| `the tsr header describes the database that produced it` | `"side"`/`"total_cells"` are the real ones |

`README.mbt.md` and the `moon.mod` description document the range, the storage
reason for the 215 limit, and the coordinate-over-position import rule.

## What this plan does not do

- It does not make the *number of axes* variable. `DIM` stays 4; `Coords` keeps
  four fields.
- It does not lift the flat-array ceiling past `side == 215`. That needs storage
  that is not one `Array` indexed by a 32-bit `Int`, and is tracked above rather
  than folded in.
- It does not change the sudoku rules. Only the size they operate at.

## Implementation record — what the work actually found

Four things turned up during steps 1-4 that the plan above did not anticipate.
All four are now recorded in the code, not just here.

**1. The `Int64` choice does not raise the ceiling, and `46,340` was wrong.**
Measured: `Int64` arithmetic alone admits `side <= 55108`, but `Array` is indexed
by `Int`, which is 32-bit on this toolchain (the compiler rejects the literal
`2147483648` as an `Int`). `MAX_SIDE` is therefore 215, and `215^4 - 1 =
2136750624` is the largest cell count that stays addressable. The `46,340` in the
first draft of this plan was `floor(sqrt(Int32::MAX))` — a *square* root bound
offered where a *fourth* root was needed. `Int64` was still the right call for
the type system; it just is not what sets the limit.

**2. `Int32` is a dead end in both directions, which is why the fields widened.**
`Int64::to_int32` and `Int32::to_int` both fail to compile, while `Int64::to_int`
and `Int32::to_int64` both work. So `Int32` cannot be reached from the index
arithmetic and cannot address storage. A comment written during step 1 claimed
there was *no* conversion between `Int32` and either width; that was false and
has been corrected in `coords.mbt` and `types.mbt`.

**3. `@json` encodes `Int64` as a JSON string, not a number.** Widening the GUI's
view structs to `Int64` silently broke the running app:
`Int64::from_json: expected number in string representation` came back from
every dispatch, and the page's `===` comparisons and `Set.has` all stop matching.
The GUI's JSON boundary therefore stays `Int32` — losslessly, because
`215^4 < Int32::MAX`, so no position the store can produce is affected. The two
GUI files carry that reasoning in their headers, because the next reader will
otherwise "fix" it back.

**4. `slot_of` takes a 1-based position; `index0` is already 0-based.** Feeding
one to the other compiles, type-checks, and reads the *wrong cell* — slot `-1`
for the first cell and off by one everywhere else. This was written nine times
during the migration and caught only because 20 tests went red. A test that
counts per-cell coverage rather than checking one cell's value is what surfaced
it; a spot check would not have.

Two latent assumptions also broke the moment `side > 3`, and were fixed in step 2
rather than left for later: the fixed 4-slot `counts = [0, 0, 0, 0]` tally (digit
domain is `1..side`, so `side == 4` indexes past its end) and `free_axis_of`,
which compared only `line[0..2]` — all of a 3-cell line, and three quarters of a
4-cell one.

## Notes for whoever reads this next

Two probes in this plan hung before they measured anything, both from the same
mistake: an overflowing `Int64` multiply wraps to a **negative** value, which
still satisfies `<= limit`. A bound-finding loop written as
`while s * s * s * s <= limit : s += 1` therefore never terminates once `s`
passes the root. Decide such bounds with a guard that returns `false` the moment
`s*s > floor(sqrt(Int64::MAX))`, or binary search a precomputed square root.
