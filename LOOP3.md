# LOOP 3 — a short-term memory tier: TTL, capacity eviction, similarity

`LOOP.md` made `side` a variable. `LOOP2.md` gave the store a clock, transactions
and a real SQL engine. This one adds the thing those were prerequisites for: a
**short-term memory** — a store whose entries expire, whose size is bounded by
the caller rather than by the lattice, and whose entries are found by similarity
rather than by equality.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `6cdd729` (v0.1.3), through the real CLI.

### The store's bound is the lattice, and overfilling it is an error

```
81 inserts -> 81 result lines; exit=0
the 82nd distinct position -> 错误: Position out of range: 82 (1..81) | 错误代码: INVALID_POSITION
```

`side = 3` gives 81 cells, and the 82nd distinct position is refused. There is
no "oldest goes" rule, because there is no notion of oldest: the store is a
*durable* one, and a durable store that silently dropped a record to make room
would be lying about what it kept.

### A key is not unique

```
the same key at two positions ->   键: dup |   值: first |   键: dup |   值: second
```

Two cells carry `dup` with different values, and `SELECT ... WHERE key='dup'`
returns both. A memory cannot work this way: "the value for `dup`" has to be one
value, or `get` has to answer a set and every caller has to decide what to do
with it.

### The only way to match part of a value is a substring

```
LIKE '%name%' matched 2 rows; LIKE '%ada%' matched 2 rows
```

`LIKE '%name%'` matched `{"name":"ada"}` and `{"other":"name"}` — one has the
key, the other has the word. `LIKE '%ada%'` matched `{"name":"ada"}` and the
bare string `ada` — one is a document, the other is a word, and the store cannot
tell them apart. Neither match is *wrong*, and both are useless: a substring
test cannot say how alike two things are, and it cannot rank them.

### There is no expiry at all

A record written at t is still there at t + anything. There is no TTL, no
`expires_at`, no way to say "this is only true for the next five minutes". The
clock landed in `LOOP2` and was used for stamps; it was never used for *policy*.

---

## The shape of the thing

A short-term memory is a **different shape of store** from a durable one, and
the difference is not cosmetic:

| | durable store (`src/tesseract`) | short-term memory (`src/tesseract_memory`) |
|---|---|---|
| bound | the lattice, `side^4` cells | a capacity the caller sets |
| key | not unique; one key per cell | one entry per key |
| lifetime | forever | a TTL, absolute or sliding |
| over capacity | `INVALID_POSITION` | an eviction, by a named policy |
| recency | not recorded | recorded, and it is what LRU evicts by |
| retrieval | equality, plus `LIKE` | equality, plus similarity |
| payload | a `GridCell` on a lattice | a string |

Putting TTL on lattice cells would mean: an expiry on a cell, a recency stamp
on a cell — so a *read* would have to *write* — and a capacity knob that could
only ever be a number below `side^4`, because the cells are what the store has.
Each of those is a change to what the core *is*, and the core is a published
package with a stated identity ("no external dependencies", "the column list
*is* the cell anatomy and it is fixed").

So the memory is **a separate tier that owns its entries**, in its own package.
It still belongs to the family: it depends on `src/tesseract` for the wall
clock and the ASCII text helpers, and it is published as part of the same
module.

### The three capabilities, and the rules each one needs

**TTL.** An entry has a deadline. There are two kinds, and the difference is
real:

- **absolute** — the deadline is fixed when the entry is written. It expires
  five minutes after it was *recorded*.
- **sliding** — the deadline is pushed forward on every read. It expires five
  minutes after it was *last used*.

A memory that forgets what was read five minutes ago but remembers what was
written five minutes ago is a cache, not a memory, and the sliding kind is the
one that is usually wanted. The flag is per entry, not per store, so one memory
can hold both kinds at once.

**Capacity eviction.** When a `put` would exceed the capacity, one entry goes.
Which one is a policy, and the policies are the ones people actually mean:

- `LeastRecentlyUsed` — the entry nobody has touched longest.
- `LeastFrequentlyUsed` — the entry nobody has read.
- `SoonestExpiry` — the entry closest to expiring. An entry that never expires
  is infinitely far from expiring, so it is evicted last.
- `OldestFirst` — the entry written longest ago.

Ties are broken by key, so the same sequence of operations always evicts the
same entry. A store that evicts differently on two runs of the same program is
a store nobody can test.

**Similarity retrieval.** Find the entries most like this text, ranked. Four
ways to mean "like", and they answer different questions:

| policy | asks |
|---|---|
| `Jaccard` | how much do these two share, as a share of their whole vocabulary? |
| `Cosine` | how similar are these two *documents*, weighting a repeated word more? |
| `Containment` | how much of the **query** does this entry cover? |
| `Structure` | do these two JSON documents have the same shape? |

`Containment` is the one that answers a search: a two-word query should match a
long document that contains both words, and Jaccard would punish that document
for being long. `Structure` is the one that a JSON store should have: two
records with the same keys are alike even when every value differs, and no
amount of word-matching will ever say so.

Over the top of similarity sits **recency weighting**: a score multiplied by
`0.5 ^ (age / half_life)`, so a half-life of an hour halves the weight of
everything written more than an hour ago. This is the single most common
retrieval rule in a short-term memory, and it is the reason the memory records
recency at all.

### What the clock does

The memory needs a time source, and it must be **injected** for the same reason
the store's clock is: a test that reads the host clock can only assert that
something did not happen. So the memory has two clocks — `System`, and `Manual`
— and `Manual` only moves when the caller says so. Every TTL boundary in the
test suite is a number, not a race.

---

## The six steps

### Step 1 — the package and its data shapes

`src/tesseract_memory`, with `Entry`, `Config`, `Stats` and `Hit`. The clock,
the TTL, the eviction policy and the similarity policy are **enums with
factory functions**, because a public enum's variants cannot be constructed
from another package — the same constraint `Clock` in the core already
documents.

### Step 2 — TTL

`Ttl` as `Never` / `Absolute(ms)` / `Sliding(ms)`, the deadline arithmetic, and
the expiry rule: an entry with deadline `D` is live while `now < D` and expired
at `now == D`. Expiry is **eager**: any operation that observes the clock first
purges what has expired, so the store never holds a dead entry and `size` is
the number of live entries.

### Step 3 — capacity eviction

`put` of a **new** key when the store is full evicts one entry by the policy
and then inserts. `put` of an **existing** key replaces it in place and evicts
nothing — overwriting a key must not cost another key its place.

### Step 4 — similarity

Tokenisation (lowercase, split on non-alphanumeric), the three token
similarities, and the JSON structure flattening that `Structure` compares.

### Step 5 — search

Top-k over the live entries, with the recency weight applied, ties broken by
key, and only hits with a score above zero returned.

### Step 6 — the gates

The same gate the module already runs, plus a `cmd/memory` that drives the
whole thing from a shell, because a capability that cannot be seen from a
terminal has not been shown to work.

---

## Record — what the work actually found

### The clock was the easy part; the semantics were not

The boundary is the whole contract, so it is worth writing down exactly: an
entry with deadline `D` is live while `now < D` and expired at `now == D`. A
TTL of 1000ms gives **exactly** 1000 milliseconds of life. The test that pins
it reads the value at t=999 and at t=1000.

Eager expiry turned out to be the right shape, and not only for tidiness. If
expired entries stayed in the map until something swept for them, then `size`
would be "how many entries are stored" rather than "how many are live", and
two callers of the same store would disagree about what the store holds. Now
every operation that observes the clock first removes what has expired, and
the map never holds a dead entry.

### The tokenizer was the biggest surprise

The first version of the tokenizer split on non-alphanumerics and called the
runs "words". That is right for English and **useless for Chinese**, which has
no spaces: every Chinese sentence would tokenize to the empty list, and every
Chinese document would score 0.0 against every other one. The rule is now that
a character outside ASCII is a word of its own, so `苹果手机` is four words and
two Chinese sentences share the words they have in common.

Splitting by character is crude next to a real segmenter, and it is the
difference between a useful score and no score at all. It is also a decision
that belongs in the code rather than in a footnote, because the alternative
looks like it works right up until someone stores Chinese in it.

### Four of my own expectations were wrong, and the arithmetic caught them

The similarity tests failed the first time, and in every case the
implementation was right and the expectation was not:

| what I expected | what it is | why |
|---|---|---|
| `jaccard("cat cat dog", "cat")` = 1.0 | 0.5 | Jaccard is over *sets*: the vocabulary is `{cat, dog}` against `{cat}` |
| `containment("red apple", "red pear")` = 1.0 | 0.5 | only one of the query's two words is covered |
| `structure_similarity` of two documents sharing one key = 1.0 | 0.33 | three paths, one in common |
| the entry named "exact" is the best match | the other one | it had the *longer* value, and the short one shares the whole query |

Each of those is a number that can be written out and checked, and writing it
out is what turned "I expected 1.0" into "one of three paths, so 0.33". A
similarity test that only asserts "these two are similar" would have passed
every one of those.

### A manual clock that does not move cannot say which entry is older

The LRU test failed for a reason worth recording: the test wrote two entries
without advancing the clock, so both had the same `last_seen`, the policy had
nothing to choose between them, and the tie-break by key sent `a` out. The
implementation was right — two entries written at the same instant *are* tied —
and the test was wrong, because "least recently used" is only a question when
the times differ.

This is the same lesson the core's own clock has: a test that cannot move time
cannot assert anything about time.

### Four things the toolchain said no to

- `Int64::max_value()` **does not exist**. The "infinitely far from expiring"
  rank is a literal, `9223372036854775807L`.
- `Double::pow` is **deprecated** in favour of `@math.pow`, so the package
  imports `moonbitlang/core/math` — a core package, so still no dependency.
- A `mut` field means **the field can be reassigned**, not that the fields
  inside it are mutable. `self.stats.puts = ...` needs `mut puts` on `Stats`,
  and the `mut` on `Memory::stats` is then *unused* and the toolchain says so.
- The core's `pad_left` pads with **spaces**. A score needs zeroes, and
  `pad_number` is the one that does that.

### The public enums are built by functions, not by writing the variant

`Clock` in the core already documents this: a public enum's variants cannot be
*constructed* from another package, so `Ttl`, `EvictionPolicy`, `Similarity`,
`Recency` and `MemoryClock` each have factory functions. Matching is fine —
the CLI matches on `Ttl` to work out a window — and construction is what is
refused.

### The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   266 passed / 0 failed   (was 240 before this LOOP)
cli-smoke.mjs   20 PASS / 0 FAIL   (was 14)
```

`memory_test.mbt` holds 26 tests, one per rule rather than one per method, and
each names the behaviour it protects: the TTL boundary, the two kinds of
deadline, the four eviction policies, the tie-break, the four similarities, the
recency weight, and the fact that a search is not a use.

---

## What this deliberately does not do

- **Not SQL, and not a second query language.** The memory has a native API.
  Putting it behind tesseract's SQL would mean the core's executor learned
  about a tier it does not own, and the two packages would have to import each
  other.
- **Not embeddings.** A semantic similarity needs a model, and a model is a
  dependency and a download and a GPU. The four similarities here are lexical
  and structural, and they are *exact* — the same text always gives the same
  score, with no model to drift.
- **Not persistent.** A short-term memory is the tier above the durable store,
  not a replacement for it. What is worth keeping is what the durable store is
  for.
- **Not thread-safe**, for the same reason the core is not: the runtime is
  single-threaded, and the store is mutated in place.
