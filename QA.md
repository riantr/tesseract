# QA — a deep sweep across sixteen dimensions

Measured against the tree that ships as **v0.1.14** — the revision that follows the
0.1.13 sweep. Every number below was produced by a tool in `qa/`, and every tool
prints where its number came from. A number that could not be measured says so
instead of carrying an estimate.

The sweep that found the defects ran against 0.1.13. This round **acted on what it
found**: the findings that were defects are fixed, the findings that were questions
about what the package should offer are answered and recorded, and every number
below was re-measured afterwards.

**v0.1.14 is published.** The registry's latest version is 0.1.14, and the probe
that measures what a consumer actually gets now passes **9 of 9** against it: the
four checkpoint defects are closed in the artifact, not only in the tree, and
every accessor of the two opaque value types returns the number the contract
names. Getting there took a fix to the release, five fixes to the audit, and
one hole in the house gate — see "The release failed" below.

---

## The numbers

| # | dimension | the number | the tool |
|---|---|---|---|
| 1 | **SAST** | 71 files / 14 packages, **0 errors, 0 warnings**; 17 `unwrap`s classified as 8 guarded, 4 bounded, 5 waived, **0 unproven**; **0** SQL concatenations; 106 `Int64`→`Int` narrowings measured | `node qa/sast.mjs` |
| 2 | **DAST** | **119** hostile argv vectors against 5 binaries; **104** deliverable, all refused cleanly; 15 undeliverable (the OS command-line limit); **0 crashes, 0 hangs** | `node qa/dast.mjs` |
| 3 | **Dependency / SCA** | **14** modules in the closure, **6** direct pins, every pin current; 0 yanked; vendored SQLite **3.49.1** against upstream 3.54.1; **4** NVD advisories, **0** reachable; **1** transitive gap left | `node qa/deps.mjs` |
| 4 | **Unit** | **422 tests, 422 passed, 0 failed**, on 4 check targets under `--deny-warn` | `moon test --target wasm --deny-warn` |
| 5 | **Integration** | **22** production edges across 14 packages (+1 test-only); **11** crossed by an in-tree test that names the other package; **11** covered only from outside the package | `node qa/integration.mjs` |
| 6 | **API** | **523** public symbols (62 types, 169 fns, 285 methods, 7 consts); naming **100 %** conformant; **0 findings** (75 in the 0.1.13 sweep) | `node qa/api.mjs` |
| 7 | **Contract** | **523** published symbols matched, **0** mismatched; the published package's own interface files **15 identical, 0 differing**; every published accessor **returns the number the contract names**; the probe of the published artifact: **9 tests, 9 passed**; **12** error codes, **12/12** documented and **12/12** asserted on the code; **0** findings in the working tree, **3** in the published artifact, **0** drift | `node qa/contract.mjs` |
| 8 | **Component** | **8** library packages, coverage from **15.6 %** to **98.5 %**; **0** API findings across the module's packages | `node qa/api.mjs`, `node qa/coverage.mjs` |
| 9 | **Gherkin** | **7** features, **54** scenarios, **222** steps, **54/54** pass | `node qa/gherkin.mjs` |
| 10 | **E2E** | **72** commands across **5** CLIs mapped onto **4** layers; **0** exercised by no layer; **5** exercised only by the unit suite | `node qa/e2e.mjs` |
| 11 | **Coverage** | whole module **3484/4966 = 70.2 %**; libraries **3484/4423 = 78.8 %**; binaries **0/543** | `moon coverage analyze -- -f cobertura`, `node qa/coverage.mjs` |
| 12 | **Fuzz** | **6** properties × **3000** rounds ≈ **18,000** hostile statements, all pass, error vocabulary closed | `cd qa/fuzz && moon test --target native` |
| 13 | **Performance** | index rebuild exponent **0.67**, lookup **0.69**; the index's own share **0.35 ms/entry** against the store's **1.36 ms/entry**; checkpoint write **0.20**, size **0.52**; lattice cost **1.03**; opening the store **0.86** | `node qa/perf.mjs` |
| 14 | **Load** | the durable store over 50 → 255 puts: exponent **1.15** — the cost of a put grows with the store; per-put **6.54 → 11.11 ms** (ratio 1.70×). The SQL store's own statements sit below the log clock's resolution (ratio 1.33×, **not resolved**) | `node qa/perf.mjs` |
| 15 | **Duplicate code** | **34** duplicated blocks / **240** duplicated lines over 71 files (28 blocks in library code, 6 in tests) | `node qa/dup.mjs` |
| 16 | **Metrics** | this table; and the defects below, with the proof that each one was real | — |

---

## What this round changed

The 0.1.13 sweep closed on **75 API findings**, **22 integration edges of which 5
were crossed**, and a published artifact that still carried four HIGH checkpoint
defects. This round is the revision: the findings that were defects are fixed, the
findings that were questions are answered, and the audit tools grew the rules that
hold the answers in place.

### 1. A caller could hand-build a `Lattice` that disagrees with itself — 6 → 0

The API audit's rule **A3.1** reports a public function that takes a value whose
public fields it does not check. `Lattice` had eight public fields, so a caller
could build one by hand and `new_db` would trust all of it: `stride_y = 0` divides
by zero, a `last_position` past the end makes `new_db` try to allocate a billion
cells, and a position lookup can miss.

The fix is not a check inside `new_db` — it is making the inconsistent lattice
**unrepresentable**:

- `Lattice`'s eight fields are `priv`. The only way to obtain one is
  `lattice_of(side)`, which refuses a side it cannot address.
- Five public accessors carry what the fields used to: `side()`, `total()`,
  `first_position()`, `last_position()`, `max_digit()`.
- Every call site now reads the lattice through an accessor: **22** reads in
  production code across 5 packages, and 124 more in the test suite.

The rule did not get weaker. It still reads the public fields of a public struct and
asks whether an entry point trusts them — but there is nothing left for a caller to
hand it, and the audit's own field collector does not see a private field as public.
**6 → 0.**

### 2. 59 public symbols that nothing held in place — 59 → 0

- **A4.1 (25)** — a public symbol nothing else in the module references.
- **A4.2 (34)** — a public symbol only the module's own tests reference.

Three separate causes, and the third is the one worth the most.

**(a) The last two value types still showed their fields.** `Entry` and `Hit` were
the only value types in the module left with public fields — 12 and 6 of them. Both
are now opaque, with 9 new public accessors on `Entry` (`scope`, `key`, `value`,
`added_at`, `deadline`, `window_ms`, `sliding`, `last_seen`, `hits`) and 6 on
`Hit`. `Entry`'s other four accessors (`importance`, `metadata`, `pinned`, `kind`)
already existed; the struct now has one accessor for every field it has.

**(b) Other packages were reading those fields.** 28 reads in production code
across 5 packages now go through the accessors: `tesseract_memory_db` 11,
`tesseract_memory_cli` 10, `tesseract_memory_index` 5, `tesseract_memory` 2.

**(c) The library was reading its own values through the back door, and had
started duplicating what its accessors already said.** This is where the audit
found a real bug rather than a style problem:

| the duplication | what it cost |
|---|---|
| `parse_session` wrote the CLI's default options out **twice** | two spellings of one set of defaults, which had already drifted — the parser now starts from `default_options()` |
| `Ttl::is_valid` re-derived what `is_never()` says | two answers to "does this entry ever expire" |
| `Ttl::deadline` re-derived what `is_sliding()` says | two answers to "does a read push the deadline" |
| `Memory::pick_victim` re-derived `idle_ms` | the clock was read inside the loop instead of once |
| `new_logger` re-derived the logger's own clock | — |
| `TesseractLogger::add` re-derived its own count | — |
| `Tesseract::in_transaction` was re-implemented as a private copy | **7** private copies inside `txn.mbt` |
| `cell_count` was re-derived in the DGP package | — |
| six struct literals in `tesseract_sa` bypassed constructors that already existed | `RunSummary`, `Finding`, `UnparsedGroup`, `ByKind`, `ScanReport`, `FileResult` |

**A4.1 → 0, A4.2 → 0.** The 31 symbols the library deliberately does not call
itself — `all_slabs`, `fixed_clock`, `neighbours`, `solve_lattice` and the rest —
are a *caller's* API, and the library has no business calling them. They are
recorded in the audit's per-item waiver list, each with the reason it exists, and a
waiver that no longer matches anything in the module is now reported as **A5.1**.

### 3. Six library edges were crossed only from outside the package — 5 → 11

Every library-to-library edge is now crossed by a test that names both packages.
The six that were not are closed:

| the edge | what crosses it now |
|---|---|
| `memory_cli → tesseract`, `memory_cli → tesseract_memory` | `src/tesseract_memory_cli/cli_test.mbt` — **new**; the package had no test file at all and sat at **0 %** coverage, and it is now at **15.6 %** |
| `memory_db → tesseract`, `memory_db → tesseract_sqlite` | `src/tesseract_memory_db/store_test.mbt` reads the checkpoint back through `@tesseract_sqlite.load` into a core lattice |
| `memory_index → tesseract` | `src/tesseract_memory_index/index_test.mbt` asserts the core's folding and ordering against the runtime's length-first `String::compare` |
| `tesseract_sa → tesseract` | `src/tesseract_sa/sa_test.mbt` asserts a finding's numbers against what the core reads out of the line |

The 11 `cmd/*` edges are crossed from outside the package instead — the
command-line smoke suite and the Gherkin features drive those binaries as real
processes, which is a stronger crossing than a test in the same package.

### 4. The error vocabulary — recorded as a decision, not churned into the surface

**A2.1 (8)** and **A2.2 (2)** report a package that mixes `Result[..., String]`
with a structured error, or that reports every failure as prose. The audit measures
a *shape*, not whether the shape is right.

Every current caller of the eight prose-error functions shows the failure to a
person, and none of them branches on it. Unifying them is a change to **eight
published signatures, ~86 call sites and the README's error table** — so it is
planned as **its own release** rather than folded into the release that already
breaks the surface for the opaque value types. One breaking change per release is
legible; two unrelated ones are not.

Each of the ten findings is now recorded in the audit's per-item waiver list with
that reason, and the audit prints them on every run. **A2.1 → 0, A2.2 → 0.**

### 5. The audit tools grew three rules, and every one of them was mutation-proven

A green rule proves nothing until it has been made to fail. Each of these was
broken on purpose, seen to go red, and reverted:

| the mutation | what it produced |
|---|---|
| a typo in one A4 waiver key | A4.2 = **2**, A4.3 = **1** |
| `logical_clock()` removed from `new_logger` | A4.2 = **1** |
| the last `pad_left` reference removed | A4.1 = **1** |

### 6. The end-to-end map counted its own definition as a check

`qa/e2e.mjs` counted the occurrences of `check(` in the smoke suites, which
included the `function check(` definition and the word `check(` inside a failure
message — **105** and **47** where the suites run **103** and **45**. The count now
matches the calls, and the tool's own header comment no longer quotes the numbers
of a previous round.

### 7. The release failed, and the audit was measuring a version that had moved on

The v0.1.14 publish run failed in **15 seconds**, at the step that asserts there
is exactly one module to publish: it found **three**. There was one before the QA
sweep and there are three now, because `qa/fuzz` and `qa/contract_probe` are
nested modules with their own `moon.mod`, and the QA sweep added them *after*
v0.1.13 was tagged.

The guard was right to fire — a second module in the tree is exactly what it is
there to catch — so it was taught about `qa/`, where every file is a test fixture
with its own gate, and it still fails loudly about a module anywhere else. The
release was then re-run against the same tag: **published, and the GitHub Release
is live.**

Three more things turned up while the round was closing, and all three were
defects in the *measurement*, not in the module:

- **The audit measured a version that no longer existed.** `qa/contract.mjs` carried
  its own copy of the published version (`0.1.13`) while the probe module had
  already been moved to `0.1.14` — so the audit compared the tree against the last
  release and reported a drift of 2 removed and 15 added symbols that had already
  shipped. The version is now read out of the **probe module's own pin**, so the
  two cannot disagree: there is one place to bump.
- **The audit did not recognise a refusal that came earlier.** C2.6 asked whether
  the probe printed `reload_err` — the fact a build emits when it refuses at the
  *reload*. A build that refuses the bad file at the *open* never reaches the
  reload, so the refusal happened and the audit called it a failure. The check now
  asks whether the probe refused at all, and says where.
- **The probe inherited the last run's file.** The probe's files live in a
  directory that survives the run, and a checkpoint left with a rewritten header
  cannot be opened — so the run after a failed one reported the *previous* run's
  corruption as its own result. Every probe file is removed before it is written
  now.

And one thing the probe was not measuring at all: it opened the *bad* file and
then reloaded it, so on a build that refuses early it was measuring the open
twice and the reload never. The probe now opens the **good** file, corrupts it
afterwards, reads the corruption back to be sure it took, and then reloads — which
is the only order that reaches the reload on a build that refuses at the open. It
also asserts that the store kept what it held when the reload was refused.

Both ends of that are proven by mutation:

| the probe against | the result |
|---|---|
| the published **0.1.14** | **9 / 9 pass** — the reload is refused, the store keeps its 2 entries, and every accessor returns the number the contract names |
| the published **0.1.13**, the 8-test probe of the refusals alone | **4 / 8 fail**, including *"a reload of a checkpoint with an unknown version was accepted"* |
| the published **0.1.13**, with the accessor test added | the module **does not compile** — *"Type `Lattice` has no method `side`"* — because 0.1.13 has no accessors at all |

The last row is the probe reporting the release from the other side: 0.1.14
added the accessors, and a consumer that had them must have had 0.1.13 or
earlier.

### 8. The published surface was advertised but never called

0.1.14 is a release whose whole content is a set of **accessors**: `Lattice`,
`Entry` and `Hit` became opaque, and the published surface grew one accessor
per field. The contract audit compared the registry's index with the tree, which
proves the index *advertises* the right names — and says nothing about whether
a consumer can **call** them. An accessor the index names and the package does
not have breaks the consumer's build; one that returns the wrong value breaks
it quietly.

Nothing in the tree exercised the published accessors, because the probes read
the *checkpoint* format and the fuzz suite builds a default lattice without
reading its shape. So the release's headline change had never been run by a
consumer.

The probe now does it, against the published package:

| the check | what it asserts |
|---|---|
| **C1b** — the published surface, *called* | `lattice_of(4)` gives `side() = 4`, `total() = 256`, `first_position() = 1`, `last_position() = 256`, `max_digit() = 4`; a `put` gives `scope() = "default"`, `key()`, `value()`, `hits() = 0`, `sliding() = false` |

Three mutations, three failures:

| the mutation | what it produced |
|---|---|
| the probe's expected side changed to 5 | the probe failed: `4 != 5` |
| the probe pinned **0.1.13** | the probe **did not compile** — *"Type `Lattice` has no method `side`"* — because 0.1.13 has no accessors at all. The probe is reading the published package, not the tree. |
| the probe printed a wrong `lattice_side` | the audit reported `FAIL [C1b] (published 0.1.14) … wrong: lattice_side=999 (expected 4)` and recorded a **HIGH** published finding |

The audit's C1b failure is reported in the **published** scope and does not fail
the tree's exit code, which is the audit's own rule: the exit code means *the
tree has a defect*, and a published artifact is not the tree. The probe now
runs **once** and both checks read its facts — it is a nested module, so a run
is a build against the published package and is not cheap.

### 9. Two nested modules were never gated at all

`qa/fuzz` and `qa/contract_probe` have their own `moon.mod`, so the root
module's `moon fmt --check` and `moon check` **never see them**. Both had been
unformatted for as long as they existed: the probe module's files and the fuzz
module's files were both written by hand and never run through `moon fmt`.

The fuzz module's formatter pass is not cosmetic. It reflowed the statement
vocabulary and the mutation templates onto the toolchain's own line width, and
it normalised one signature from `Int` to `Int32` — the same type under a
different spelling, which is the kind of thing a formatter settles and a human
reviewer never notices.

The house gate now gates the nested modules too, and `AGENTS.md` says so. The
two of them are also the only places in the repository that build against the
**published** package rather than the tree, so their tests are the only ones
that can see a release breaking a consumer.

---

## What the 0.1.13 sweep found, and what this round closed

Each of these was a defect, not a smell. Each was **shown to go red** before the
fix was accepted, because a green rule proves nothing until it has been made to
fail.

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
**Against the old code all four fail; with the fix, 21/21 pass.** The four
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

Closing this took the API audit's rule A3.1 from **17 findings to 6** — the
eleven that concerned these two functions are gone, because a function that is
not public cannot be an entry point. **This release closes the other six**, so the
rule is now at zero.

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
been green about code that is no longer the code that ships. Every direct pin is
current at 0.1.14.

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

**The claim is now true in a second sense as well: `Lattice`'s fields *are*
private**, and the waiver says so.

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

### The error vocabulary is not unified — A2.1 (8) and A2.2 (2)

Answered and recorded rather than churned into the surface: see
"What this round changed → 4". The unification is planned as its own release,
because it changes eight published signatures, ~86 call sites and the README's
error table, and a release that breaks the surface in two unrelated ways is a
release nobody can read.

### 31 public symbols the library does not call itself

`all_slabs`, `coord_filter`, `fixed_clock`, `line_key`, `neighbours`,
`pad_left`, `parse_error_message`, `peer_count`, `plane_through`,
`solve_lattice` and 21 more. Each is a caller's tool that the library has no
use for, and each is recorded in the audit's per-item waiver list with the
reason it exists. A waiver that stops matching is reported as A5.1, so the
list cannot rot silently.

### 11 package edges crossed only from outside the package

The 11 `cmd/*` edges are crossed by the command-line smoke suite and the
Gherkin features, which drive the binaries as real processes — a stronger
crossing than a test in the same package. **Every library-to-library edge is
crossed by an in-tree test**; that was the half this round closed.

### The registry's index names the executables' types — 3 LOW findings

The published index lists 22 types in the `cmd/*` packages — `Cli`, `StateReq`,
`CellView` and their kin — that no consumer can reach, because an executable
package cannot be imported at all. The registry builds that index from the
packages' own interface files, so every re-publish reproduces it, and it is not
this repo's to fix. The three findings are `LOW`, they are about the registry's
index rather than about the module's code, and they do not make the exit code
non-zero: the exit code means *the working tree has a defect*.

### The four checkpoint defects are closed in the artifact, not only in the tree

They were fixed in the tree in the previous round and were closed in the
published package by this one. The probe of the published 0.1.14 passes 9 of 9:
the unknown version, the wrong header key, the missing header and the reload are
all refused, the store keeps what it held when the reload is refused, and every
accessor of the two opaque value types returns the number the contract names.

---

## What is not claimed

- **The published 0.1.14 is clean where it was measured, and that is not the
  same as audited.** The probe covers the checkpoint contract's four refusals,
  the round trip, and the accessors of the two opaque value types; the
  published package's interface files are byte-identical to the tree's. The 3
  `LOW` findings against the published artifact are about the registry's index,
  not about the module's code, and every re-publish reproduces them.
- **Coverage of `cmd/` is 0 %.** The binaries have no in-process tests; they
  are driven as processes by `cli-smoke.mjs` (**103** checks) and `gui-smoke.mjs`
  (**45** checks), and the line-coverage tool cannot see that.
  `src/tesseract_memory_cli` was the same — 0 %, covered only from outside the
  package — and is now at **15.6 %** because it has a test file of its own.
  15.6 % is not good coverage; it is the difference between none and some.
- **Two measurements sit at the floor of what this machine can resolve**, and
  are printed as floors rather than as laws: the checkpoint's reload time
  (1.0 … 13.0 ms against a ~40 ms process launch, so the exponent 0.77 is
  fitted over a range the clock barely resolves) and the SQL store's drift
  over a run (the log clock is 1 ms and the whole run spans 10 ms — the
  1.33× ratio is **not resolved**). The durable store carries the drift
  answer instead: 1.70× over 50 → 255 puts, exponent 1.15.
- **The durable store's per-block figures are single samples of a cost the
  disk decides.** The exponent over the whole run (1.15) is the one that
  holds; the 6.54 → 11.11 ms figures move about between runs.
- **The full side-5 lattice cannot be loaded in one process** here: the
  command line exceeds what the platform carries, so the executor's largest
  measured load is 384 rows, not 625.
- **Peak memory of a large lattice was not measured.** The cell count and the
  open time are reported instead.
- **The audit tools are not a substitute for a human reading the diff.** They
  read the tree; they do not read the intent.
- **A rule that reports zero findings is not the same as a defect that does
  not exist.** Every rule that moved here was made to fail on purpose, and the
  mutation is named above.

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
depend on the **published** `riantr/tesseract@0.1.14`, so they measure what a
consumer gets rather than what is sitting in the working tree — which is why the
checkpoint contract reports its findings against the published artifact and none
against the tree. The version is pinned in `qa/contract_probe/moon.mod`, and the
contract audit reads it from there: one place to bump when the next release
lands.

The house gate, unchanged and green at the end of this round:

```sh
moon fmt --check
moon check --target wasm --deny-warn
moon check --target js --deny-warn
moon check --target native --deny-warn
moon check --target wasm-gc --deny-warn
moon test --target wasm --deny-warn     # 422 passed, 0 failed
moon build --target wasm
typos
node cli-smoke.mjs                      # 103 checks
node gui-smoke.mjs                      # 45 checks
```

And the two nested modules, which the gate above does not see:

```sh
cd qa/contract_probe && moon fmt --check && moon check --target native --deny-warn && moon test --target native   # 9 passed
cd qa/fuzz && moon fmt --check && moon check --target native --deny-warn && moon test --target native               # 6 passed
```
