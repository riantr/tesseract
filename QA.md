# QA — a deep sweep across sixteen dimensions

Measured against `6390fa9` (v0.1.13). Every number below was produced by a tool
in `qa/`, and every tool prints where its number came from. A number that could
not be measured says so instead of carrying an estimate.

This is **not** a release. The tree at the end of this round is green under the
house gate and carries fixes that the next release will ship; the registry still
carries 0.1.13, and the report says plainly which defects that means.

---

## The numbers

| # | dimension | the number | the tool |
|---|---|---|---|
| 1 | **SAST** | 68 files / 14 packages, **0 errors, 0 warnings**; 17 `unwrap`s classified as 8 guarded, 4 bounded, 5 waived, **0 unproven**; **0** SQL concatenations; 106 `Int64`→`Int` narrowings measured | `node qa/sast.mjs` |
| 2 | **DAST** | **119** hostile argv vectors against 5 binaries; **104** deliverable, all refused cleanly; 15 undeliverable (the OS command-line limit); **0 crashes, 0 hangs** | `node qa/dast.mjs` |
| 3 | **Dependency / SCA** | **14** modules in the closure, **6** direct pins, **0** yanked; vendored SQLite **3.49.1** against upstream 3.54.1; **4** NVD advisories, **0** reachable; **1** pin moved (doubleML 0.164.33 → 0.164.35); **1** transitive gap left | `node qa/deps.mjs` |
| 4 | **Unit** | **406 tests, 406 passed, 0 failed**, on 4 check targets under `--deny-warn` | `moon test --target wasm --deny-warn` |
| 5 | **Integration** | **22** production edges across 14 packages (+1 test-only); **5** crossed by an in-tree test that names the other package; **17** covered only from outside the package | `node qa/integration.mjs` |
| 6 | **API** | **509** public symbols (62 types, 169 fns, 271 methods, 7 consts); naming **100 %** conformant; **75** findings, of which **11** were closed this round | `node qa/api.mjs` |
| 7 | **Contract** | **508** published symbols matched, **0** unexpected; **12** error codes, **12/12** documented and **12/12** asserted on the code; **0** findings in the working tree | `node qa/contract.mjs` |
| 8 | **Component** | **8** library packages, coverage from **0 %** to **98.5 %**; **75** API findings across the module's packages | `node qa/api.mjs`, `node qa/coverage.mjs` |
| 9 | **Gherkin** | **7** features, **54** scenarios, **222** steps, **54/54** pass | `node qa/gherkin.mjs` |
| 10 | **E2E** | **72** commands across **5** CLIs mapped onto **4** layers; **0** exercised by no layer; **5** exercised only by the unit suite | `node qa/e2e.mjs` |
| 11 | **Coverage** | whole module **3357/4934 = 68.0 %**; libraries **3357/4397 = 76.3 %**; binaries **0/537** | `moon coverage analyze -- -f cobertura`, `node qa/coverage.mjs` |
| 12 | **Fuzz** | **6** properties × **3000** rounds ≈ **18,000** hostile statements, all pass, error vocabulary closed | `cd qa/fuzz && moon test --target native` |
| 13 | **Performance** | index rebuild exponent **0.59**, lookup **0.58**; the index's own share **0.30 ms/entry** against the store's **1.44 ms/entry**; checkpoint write **0.17**, size **0.52**; lattice cost **1.10** | `node qa/perf.mjs` |
| 14 | **Load** | the durable store over 50 → 255 puts: exponent **1.09** — **flat**: it does not get slower as it fills; per-put **8.84 → 9.82 ms** (ratio 1.11×) | `node qa/perf.mjs` |
| 15 | **Duplicate code** | **34** duplicated blocks / **240** duplicated lines over 68 files (28 blocks in library code, 6 in tests) | `node qa/dup.mjs` |
| 16 | **Metrics** | this table; and the defects below, with the proof that each one was real | — |

---

## The defects that were found, and fixed

Each of these was a defect, not a smell. Each was **shown to go red** before
the fix was accepted, because a green rule proves nothing until it has been
made to fail.

### 1. The checkpoint reader read files it did not understand — 4 HIGH

The format's own words: *"A checkpoint that carries a version this build does
not know is refused rather than half-read."* The code did not do that.

| the case | what the published 0.1.13 did |
|---|---|
| a header carrying an unknown format version | read it, on the caller's clock — so the minute-lived entry was **silently dropped** |
| a header cell whose key is not this format's | read it as a checkpoint (`open=ok entries=2`) |
| a checkpoint with no header cell at all | read it as a checkpoint |
| a `reload` of such a file | accepted it, and the store had already been emptied |

The fix: `decode_header` returns `Result[MemoryClock, String]` with a message
that names the reason; `read_header_cell` returns a `Result` that separates
"this is not a checkpoint" from "this is a checkpoint I cannot read"; `open`
refuses a file that holds cells but has no readable header (a file with zero
cells is still a new store); and `reload` checks the header **before** it
clears the store, so a refusal leaves the store holding what it held.

Four regression tests went into `src/tesseract_memory_db/store_test.mbt`.
**Against the old code all four fail; with the fix, 20/20 pass.** The four
cases are also measured from outside the package, by the probe in
`qa/contract_probe/`, which runs against the *published* package.

### 2. `Tesseract::write_cell` panicked on an out-of-range position — 1 HIGH

`write_cell` was public, returned `Unit`, and wrote whatever it was given:

```moonbit
let slot = slot_of(position)   // slot_of(0) == -1
db.cells[slot] = cell           // index out of bounds
```

Reproduced: with `write_cell` public, `write_cell(db, 0, cell)` raises
`PanicError`. A consumer of the published package could crash the process with
one call.

It is now **package-private**, along with `write_all`. Both are internal
machinery — `write_cell` is *"the single point every mutation goes through"*,
and the README already describes it that way — and every caller of both is
inside `src/tesseract`. While public they were also *unchecked*: `write_cell`
would store a cell whose own key, value and digit the library refuses
everywhere else, so a bad value was accepted at the write and failed later,
somewhere else, as a different kind of failure.

Closing this took the API audit's rule A3.1 from **17 findings to 6**: the
eleven that concerned these two functions are gone, because a function that is
not public cannot be an entry point.

### 3. `.quit` had no regression test — 1

The "stop consuming arguments" behaviour was a previously-fixed bug with no
test in any layer. `cli-smoke.mjs` now carries **4** checks for it, asserting
on ASCII markers (`records :`, `INSERT`) rather than on the Chinese response
wording, so a translation does not break them.

### 4. Seven assertions read the message and never the code — 7

The code is what a caller branches on; the message is prose that may be
reworded. Four of the seven sat in `txn_test.mbt` and now assert the code as
well. The other three already did.

The **rule** that found them was also wrong, and that was the more interesting
half. It scoped "message-only" per *assertion*, so a test that pinned the code
on one line and read the wording on the next was reported as missing
something it had. It now scopes per **test**, and pairs by **value**: the
message of `r` is excused by the code of `r`, not by the code of some other
value in the same test. Re-scoped, the rule reports **0** findings — and it is
no longer vacuous: deleting one code assertion makes it fire, and that
mutation was run.

### 5. A stale dependency — 1

`riantr/moonbit_doubleML` 0.164.33 → **0.164.35**, moved by hand and
confirmed by the diff of `moon.mod`. The whole gate was then run *under the new
pins*, which is the part that matters: green under the old ones would have
been green about code that is no longer the code that ships.

### 6. The line count had two spellings — 1

`cmd/main` named it (`sudoku_line_count`) and `cmd/persist` wrote the
arithmetic out inline. The values were identical, so the drift was in
encapsulation, not behaviour — but the agreement was a coincidence, because
nothing tied the two spellings together. The count now has one definition, in
`src/tesseract`, next to the `all_lines` whose count it is, and a regression
test asserts that the count is the number of lines.

The duplicate-code number went **234 → 240** as a result, and that is worth
saying plainly: the detector counts *textual* duplication, and the two files
now agree in two more places, so it sees one longer contiguous match. The
duplicated *logic* went down — the formula exists once now, in the package
that owns the thing being counted.

### 7. A false positive in the gate itself — 1

`typos` failed the build on `node.childs` in `qa/contract.mjs`. `childs` is
not a typo: it is the key the Mooncakes registry really uses in its published
`module_index.json`. The word is now declared in `_typos.toml`, with the
registry's URL in the comment, so the spelling check stays honest instead of
teaching the reader to ignore it.

### 8. A waiver in the audit tool that was not true — 1

The SAST tool waived five `unwrap`s, each on the strength of a stated
invariant. One of them said *"Lattice's fields are private, so a caller cannot
build a lattice that disagrees with its cells."* **They are not private** —
MoonBit's `pub struct` exposes its fields, they are in the published
`pkg.generated.mbti`, and five packages read them. A waiver is a claim, and a
false claim is worse than no waiver at all. The claim is now the true one (the
only writer of a cell is package-private, so a stored cell's position always
agrees with its slot), and every waiver names the precondition it rests on.

### 9. The contract audit was measuring the wrong thing in two places — 2

Both were found by mutation, and both are the kind of defect that makes a QA
number a lie:

- The published-artifact findings and the working tree's findings were one
  list. The four checkpoint defects above are real **in the published
  0.1.13** and fixed **in the tree**; a single list said the tree was broken
  and said the tree was fine, in the same breath. They are now three scopes —
  the tree, the published artifact, and the drift between them — and the exit
  code means *the tree has a defect*, nothing else.
- The tree's own refusals were not measured at all. A nested module cannot
  reach the tree by path (`moon.mod` accepts only versioned registry
  dependencies), and a probe inside the tree would be a package of the tree,
  and a package of the tree is part of the published surface — which a round
  that is not a release does not change. So the tree's refusals are measured by
  the tree's own tests, with the four test names pinned in the audit: a test
  that is renamed or deleted is reported as a **missing refusal**, not as a
  silent pass. Both mutations were run.

---

## What was found and deliberately not fixed

These are findings, and they are real. They are not fixed here, and this
section says why.

### `new_db` does not check the lattice it is given — 6 findings (API rule A3.1)

`Lattice` has eight public fields, and `new_db(name, lat, logger)` trusts all
of them. A caller who hand-builds a `Lattice` can make the library divide by
zero (`stride_y = 0`), make `new_db` try to allocate a billion cells
(`last_position` far past the end), or make a position lookup miss.

The fix is an **API redesign**, not a defect fix: MoonBit's `pub struct`
exposes its fields, so the invariant can only be made unrepresentable by
turning `Lattice` into an opaque type with accessors — which changes how 23
call sites in five packages read the lattice, and adds eight public functions
to the published surface — or by making `new_db` return a `Result`, which
changes a published signature and every caller of it.

Either is a release-scale decision with a README rewrite attached. The library
already provides the safe path (`lattice_of` refuses a side it cannot address),
and the hole needs a caller to deliberately build a struct by hand. So it is
reported, not silently closed.

### 69 other API findings

- **A2.1 (8) and A2.2 (2)** — some packages report a failure as a bare
  `String` and some as a structured error. Making them uniform changes the
  published error types of three packages.
- **A4.1 (25)** — public symbols nothing else in the module references.
- **A4.2 (34)** — public symbols only the module's own tests reference.

All four are questions about what the package should *offer*, and the answers
are the project's, not the audit's. Removing a public symbol is a breaking
change; the registry's index over-reports 22 types today and a re-publish
reproduces that, so this is not a thing a release closes either.

### 17 package edges crossed only from outside the package (integration)

The 11 `cmd/*` edges are crossed by the command-line smoke suite and the
Gherkin features, which drive the binaries as real processes — a stronger
crossing than a test in the same package. The 6 library edges are covered by
package-local suites on both sides. The consequence is stated rather than
hidden: a defect in the seam between two library packages would not be caught
by a test that names both of them.

### The published artifact still carries the four checkpoint defects

They are fixed in the tree and proven there, but the registry carries 0.1.13
until the next release. A consumer reading mooncakes.io today gets the old
reader. The next release closes them.

---

## What is not claimed

- **The published 0.1.13 is not clean.** It carries the four checkpoint
  defects. The tree is clean; the artifact is not, and the artifact is what
  consumers have.
- **Coverage of `cmd/` is 0 %.** The binaries have no in-process tests; they
  are driven as processes by `cli-smoke.mjs` (**103** checks) and `gui-smoke.mjs`
  (**45** checks), and the line-coverage tool cannot see that. `src/tesseract_memory_cli`
  is the same: 0 %, covered only from outside the package.
- **Two measurements sit at the floor of what this machine can resolve**, and
  are printed as floors rather than as laws: the checkpoint's reload exponent
  (0.41) — a few milliseconds against a ~40 ms process launch — and the SQL
  store's drift over a run (the log clock is 1 ms and the whole run spans
  11 ms). The durable store carries the drift answer instead.
- **The full side-5 lattice cannot be loaded in one process** here: the
  command line exceeds what the platform carries, so the executor's largest
  measured load is 384 rows, not 625.
- **Peak memory of a large lattice was not measured.** The cell count and the
  open time are reported instead.
- **The audit tools are not a substitute for a human reading the diff.** They
  read the tree; they do not read the intent.

---

## Reproducing this

Every number above comes from a tool in `qa/`, run from the repository root:

```sh
node qa/sast.mjs          # static audit
node qa/dast.mjs          # hostile argv
node qa/deps.mjs          # dependency closure, SQLite, NVD
node qa/integration.mjs   # the module's own dependency graph
node qa/api.mjs           # public-surface audit
node qa/contract.mjs      # published surface, checkpoint contract, error codes
node qa/e2e.mjs           # command surface across four layers
node qa/gherkin.mjs       # the feature files
node qa/dup.mjs           # duplicate code
node qa/coverage.mjs      # coverage (after `moon coverage analyze -- -f cobertura`)
node qa/perf.mjs          # performance and load (about four minutes)
cd qa/fuzz && moon test --target native   # fuzz, against the published package
```

`qa/fuzz` and `qa/contract_probe` are **nested modules**: they have their own
`moon.mod`, so the parent module's build never sees them, they carry their own
gate, and they can never be published. `qa/fuzz` and `qa/contract_probe` both
depend on the **published** `riantr/tesseract@0.1.13`, so they measure what a
consumer gets rather than what is sitting in the working tree.

The house gate, unchanged and green at the end of this round:

```sh
moon fmt --check
moon check --target wasm --deny-warn
moon check --target js --deny-warn
moon check --target native --deny-warn
moon check --target wasm-gc --deny-warn
moon test --target wasm --deny-warn     # 406 passed, 0 failed
moon build --target wasm
typos
node cli-smoke.mjs                      # 103 checks
node gui-smoke.mjs                      # 45 checks
```
