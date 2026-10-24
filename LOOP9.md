# LOOP 9 — the durable memory, and the two rules that keep it honest

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes, `LOOP6.md` gave it a weight, `LOOP7.md` gave it labels, `LOOP8.md`
gave it a pin. This one gives it a **checkpoint**: a `.db` file the memory is
written to and read back from, so a memory can be closed and reopened without
losing what it was holding.

The reason to add a checkpoint and not another dimension of scoring: the store
could already say how much an entry counts, what it is labelled and whether it
must not be thrown away — but every one of those facts died with the process.
A caller who wanted a memory to outlive the run had to keep the thing
somewhere else, which is the whole thing a memory is for.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `74390e9` (v0.1.10): 361 tests, all green, 65 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.10 |
|---|---|
| to keep a memory across the process | no such thing — every entry was gone when the process ended |
| to know that a reopen brings back the entries that were *live* | no such thing — there was nothing to reopen |
| to know that a write the store refused left nothing behind | true of the store, and untestable against a file, because there was no file |

### The two rules the new shape follows from

1. **A reload brings back exactly the entries that were live** — not the expired
   ones. What comes back is the live set, not the written set.
2. **A refused write still leaves the store unchanged** — and the file with it.
   The store and the file are the same store.

---

## The shape of the thing

Six rules, and everything below follows from them.

1. **The checkpoint is a lattice of its own.** It never shares a cell with the
   sudoku records: they are different things with different rules, and a write
   that landed on the wrong one would be a bug in a layer neither of them knows
   about. The file is a *checkpoint container*, not a tesseract database a
   person would query.
2. **The deadline is absolute.** The checkpoint stores the instant an entry
   dies, not the lifetime it was given.
3. **The clock goes into the checkpoint, and comes back with it.**
4. **The checkpoint is swept before it is written**, so the file holds the live
   set.
5. **A checkpoint that does not fit the store it is opened with is refused**,
   rather than half-loaded.
6. **The side is fixed**, not derived from the capacity, so a file written by a
   store with a large capacity is readable by a store with a small one.

Rule 6 has a price and the price is the point of stating it: a durable memory
holds at most **255 entries** — one cell for the header, one for each entry.

---

## The four steps

### Step 1 — the package

`src/tesseract_memory_db`, a **separate package** rather than a change to
`src/tesseract_memory`. The file is a `.db`, and the `.db` adapter builds for
`native` and `wasm` only; putting it in the memory tier would take that tier
off `js` and `wasm-gc`. It mirrors the `tesseract_sqlite` precedent exactly.

### Step 2 — the format

One JSON object per cell. The first cell is the header — the format version and
the clock — and the cells after it hold the entries, one each.

Two details of the encoding matter:

- **An `Int64` is written as a JSON string.** JSON numbers are doubles, and a
  deadline can be `9223372036854775807`, which a double cannot hold exactly.
- **A `Double` is written as a JSON number**, because an importance of 0.5 is a
  number and reads better as one.

### Step 3 — the core learns to restore

`Memory::restore_entry` puts an entry back exactly as it was: the deadline it
had, the time it was added, how often it was read, when it was last seen. A
`put` builds a *new* entry — it stamps the time, it counts the hits from zero,
and it turns a lifetime into a deadline measured from now — which is right for a
write and wrong for a restore.

`Entry::make` is the constructor the other package can call: a public struct's
constructor is read-only across packages, so without it the durable store
could not build an entry at all.

### Step 4 — the shell

`cmd/memory_db` is the same commands as `cmd/memory` with a file behind them.
The commands moved into `src/tesseract_memory_cli`, a library both binaries
share: the two differ in **where the memory is kept**, not in what they can do
to it. The file is written after every command, so it is current when the next
command starts.

---

## What the measurement found

### The handle was the store, and nobody had said so

The first question of the loop was whether `DurableMemory::memory()` — which
returns the memory **by value** — hands back the store or a copy of it. A copy
would have its own clock, its own byte total and its own entry map, and the
checkpoint would then have been written from a different store than the one the
caller wrote to.

The existing suite already leaned on the answer: a test advanced the clock
through the handle and then checked the file, which only works if the handle
*is* the store. But "the suite happens to depend on it" is not a rule — it is a
coincidence that a refactor could break quietly. So it is now stated and
pinned: a test of its own, and a mutation that hands out a fresh memory
instead. The mutation is caught by five tests, and by that one first.

### The surviving mutation, and the fixture that was too weak

Two of the loop's rules survived a mutation, and both times the code was right
and the **fixture** was wrong. That is the finding worth keeping.

**The deadline was stored instead of the deadline.** The checkpoint wrote the
entry's `window_ms` where the `deadline` belonged. The test that should have
caught it wrote an entry at t=0 with a lifetime of 1000ms — so its deadline was
1000 *and* its lifetime was 1000, the same number, and the two could not be
told apart. The fixture was rewritten to write at t=500, where the deadline is
1500 and the lifetime is 1000, and the mutation died on the next run. A test
that cannot tell two values apart is not a test of the thing that differs
between them.

**The dead entry was taken in.** `restore_entry` refuses an entry whose time is
up, and the mutation removed that refusal. It *survived* — and the reason is
the store's own eager expiry: the dead entry was written, and then dropped at
the next observation, so nothing a caller could see was different. The store
never holds a dead entry either way.

But that is not the whole difference. A dead entry taken in **costs room**:
the store's room is spent on it, and the room comes out of a live one. So the
fixture was rebuilt around the room — the store's capacity drops to one entry,
the file holds a live entry and a dead one, and the reload has to choose. With
the refusal, the live entry keeps its place; without it, the dead entry evicts
the live one and is then dropped, and the store is empty. The assertion is
behavioural rather than a counter:

```moonbit
assert_eq(d.get("a-live"), Some("bbbb"))
```

The lesson is the one this repository keeps re-learning: **a rule whose
difference cannot be observed is not a rule yet.** The eager expiry hid the
first version of this one, and the fix was a harder fixture, not a weaker
claim.

### The clock, and the case the first version got wrong

The first version restored the checkpoint's clock whatever it was. That is
right for a **manual** clock — the entries in the file were written on that
timeline, and reading them on another would move them — and wrong for the
**system** clock, which is not a timeline at all: it is the host's clock, and
it says nothing about when anything was written. A checkpoint carrying it must
not turn a manual clock into the host's. The rule now says so, and the test
for it opens a file written on the host's clock with a manual clock and asks
which one is in force.

### A reload that read the clock and threw it away

`reload` read the checkpoint's clock and ignored it, while its own documentation
claimed the clock came back with the entries. The code was doing the honest
thing — the store keeps the clock it has, and the entries carry absolute
deadlines, so what is live is decided by that clock — and the documentation was
describing something else.

The fix was the documentation, and a test: the store's clock does not move on a
reload, and an entry that clock puts in the past does not come back.

---

## The numbers

| | v0.1.10 | v0.1.11 |
|---|---:|---:|
| tests | 361 | **376** |
| CLI checks | 65 | **80** |
| window checks | 45 | 45 |
| packages | 10 | **13** |
| durable entries | — | **255** |

Fifteen tests, fifteen CLI checks and three packages: `src/tesseract_memory_db`
(the store), `src/tesseract_memory_cli` (the shared command layer) and
`cmd/memory_db` (the binary).

Ten mutations were tried against the new code. Eight were caught the first time.
Two survived — the deadline written as a lifetime, and the dead entry taken in —
and both died once the fixture that could not tell the difference was rebuilt.
