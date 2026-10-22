# LOOP 5 — scopes: partitions of one keyspace, one budget, one clock

`LOOP3.md` built the short-term memory: TTL, capacity eviction, similarity
retrieval, and then a byte budget on top. `LOOP4.md` audited what was published
and fixed what the audit found. This one adds the thing a caller still could
not express: **more than one namespace in one memory**.

The reason to build a capability rather than audit one again: the memory
answered every question about *one* keyspace, and a caller with a work
namespace and a notes namespace had to either keep two memories — and then
keep their budgets, clocks and statistics apart as well — or encode the
namespace into the key and cut the key apart on every read. Both are worse than
saying what it is.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `13cc183` (v0.1.6): 284 tests, all green, 26 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.6 |
|---|---|
| two namespaces in one memory | two memories, and two budgets and two clocks |
| one budget across both | no such thing |
| a search over both | no such thing |
| to know which namespace a result came from | no such thing |

### The two rules the new shape follows from

1. **A scope is a partition of one keyspace, not a second store.** It shares
   the clock, the budget, the statistics and the eviction. The only thing it
   has of its own is the set of keys it holds.
2. **The limits are the store's.** The capacity and the byte budget are spent
   across every scope, and the eviction that follows a write can take an entry
   from any of them.

The second rule is the one that decides the rest. A scope with a budget of its
own would make the store's size a function of how many partitions the caller
happened to use, and "the memory holds at most `capacity` entries" would stop
being a statement about the memory.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **A scope partitions the keyspace.** A key belongs to exactly one scope, so
   two scopes can hold the same key without either seeing the other's entry.
2. **The pool is the store's.** The capacity, the byte budget and the eviction
   are shared; a write into one scope can take an entry from another.
3. **A scope is a handle, not a copy.** Two handles on one scope see one set
   of entries and one byte total.
4. **A key is unique only within a scope**, so an entry and a hit say which
   scope they are in.
5. **The order of keys is by their letters**, and that order is written out
   rather than borrowed from the runtime.

---

## The six steps

### Step 1 — the keyspace becomes two levels

`entries : Map[String, Map[String, Entry]]` — the scope, then the key. The
alternative, one flat map with the scope encoded into the key, needs a
separator that cannot appear in a scope name or a key, and every caller then
has to know that rule. A nested map has no separator, so it has no forbidden
characters, and the two levels say what they are.

### Step 2 — `Scope`

`Memory::scope(name)` hands back a handle: `name`, `put`, `put_with_ttl`,
`get`, `contains`, `touch`, `delete`, `entry`, `keys`, `entries`, `search`,
`search_keys`, `size`, `size_bytes`, `clear` and `default_ttl`.

The handle shares the store because MoonBit copies a struct with a `mut` field
by reference, and `Memory` has three. That was **measured** before the design
was written down, not assumed: a probe put through one handle and read through
another, and the byte total — a plain `mut` field of `Memory`, not the map —
moved in both directions. The probe is in the record below, not in the tree.

### Step 3 — the entry and the hit say where they are

`Entry` carries a `scope` field and `Hit` carries one with an accessor. A key
is unique only within a scope, so without it a hit from a store-wide search
could not say which entry it found.

### Step 4 — the eviction crosses scopes

The victim is a **(scope, key)** pair. Two consequences:

- The tie-break is the scope and then the key, so two entries that tie on the
  policy are separated by where they live and then by their key.
- The exclusion is of the **pair**, not of the key. An exclusion by key alone
  would spare every scope's entry with that name, and a store that could not
  evict any of them would have no way to make room at all.

### Step 5 — the order of keys

`compare_text` in the core, used by the memory's key order, its scope order and
its tie-break. Why it had to be written out is in the record.

### Step 6 — the gates

The same gate the module already runs, plus the `cmd/memory` scope surface:
`--scope`, the `scope` command, `scopes`, `search-all`, and a `clear` that
forgets one scope and a `clear-all` that forgets them all.

---

## Record — what the work actually found

### The runtime's `String::compare` is not the order of the letters

This is the finding of the LOOP, and it was not looking for it.

The scope comparison and the key comparison have to agree, and the first
version of the scope test failed on **both** of them. The cause was measured
rather than guessed:

```
"default" vs "work"   ->  1     (so "work" sorts first)
"b"      vs "aa"      -> -1     (so "b" sorts first)
"cat"    vs "cow"     -> -1
"apple"  vs "apples"  -> -1     (a prefix comes first)
```

`String::compare` compares the **lengths first**, and only then the letters.
It is a total order, so it was never ambiguous — but it is not the order the
documentation promised, and a reader who sorted a list of keys by hand would
get a different answer.

The consequence was not confined to the new code:

| | before 0.1.7 |
|---|---|
| `Memory::keys` | ordered by (length, letters) |
| `Memory::entries` | ordered by (length, letters) |
| the eviction tie-break | by (length, letters) |

The memory package was the only user of `String::compare` in the repository.
The core's SQL comparison was never affected — `compare_values` compares text
by code unit, in its own code, and was already right.

⇒ **Rule:** an order that a document promises has to be the order the code
implements, and "by key" means by the key's letters. A total order that is
merely *a* total order satisfies the determinism the rule is there for and
fails the promise it is read as.

⇒ **Corollary:** the runtime's string primitives are not always what their
names say. `String::compare` sounds like "compare the strings" and is really
"compare the lengths, then the strings". The fix is not to trust the name and
not to avoid the primitive, but to **measure** it and write the rule down.

### The test that could not fail, again

The first version of "the key being written is never the victim" was:

```moonbit
ignore(m.put("a", "12345"))
ignore(m.scope("work").put("b", "12345"))
assert_true(m.scope("work").put("b", "1234567890"))
```

It was mutated — the exclusion changed from the pair to the key alone — and it
**passed**. The reason is that the two exclusions are the same set when the
two scopes hold different key names: excluding the key `b` excludes
`("work", "b")` and nothing else, because no other scope holds a `b`.

The test now puts the **same** key in both scopes, which is the case where the
two rules differ — and it fails under the mutation, as it should.

⇒ **Rule:** a test has to distinguish the rule from the nearest wrong
implementation of it. "The exclusion is of the pair" and "the exclusion is of
the key" agree on every fixture where the keys are different, so a fixture
with different keys cannot tell them apart. This is the same lesson `LOOP4.md`
recorded about a counter that stays zero either way, in a new place.

⇒ **Corollary:** the mutation is the test of the test. Both mutations in this
LOOP were run against the whole suite, and the first one survived.

### Which method addresses which scope

The awkward part of the design is not the machinery — it is that `Memory` is
both the store and the default scope's handle, and the two want different
answers from the same method name.

`size` is the one that had to be decided. It is the **store's** count, because
the capacity is the store's and a caller comparing `size()` with `capacity()`
has to be comparing like with like: a scope's count would under-report how
full the store is, and a caller who believed it would think there was room when
there was none.

That leaves `size()` (the store) and `keys()` (the default scope) measuring
different things, which looks odd until the rule is stated: **the methods that
name a key address the default scope, and the methods that name the store's
state address the store.** `keys` names keys, so it is the default scope's;
`size` and `size_bytes` are the budget meters, so they are the store's.

The alternative was rejected for a specific reason: a **silent** wrong answer
is worse than an **obvious** mismatch. A scope count that under-reports the
fill level is a number nobody can see the wrongness of until entries start
vanishing.

⇒ **Rule:** when two readings of a name are possible, prefer the one whose
mistake is loud.

### The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   301 passed / 0 failed   (was 284)
cli-smoke.mjs   36 PASS / 0 FAIL   (was 26)
```

`scope_test.mbt` holds 16 tests, and they are the rules: two scopes holding
the same key, a handle rather than a copy, the store's count against a scope's
count, the capacity crossing scopes, the byte budget crossing scopes, the
tie-break, the shared clock, the scopes that hold something, the scoped search
against the store-wide one, the entry that says where it is, the two clears,
the shared statistics, the store's default TTL, the refused write, the victim
that is never the key being written, and the byte total across scopes.

---

## What this deliberately does not do

- **Not per-scope budgets.** A scope partitions one pool. A scope with a
  budget of its own would make the store's size a function of how many
  partitions the caller used, and the capacity would stop being a limit on the
  memory.
- **Not per-scope clocks.** One clock, one store: a scope that had its own
  would be a second store wearing a hat.
- **Not persistence.** The memory is still the tier above the durable store.
- **Not thread safety**, for the same reason the core is not: the runtime is
  single-threaded and the store is mutated in place.
- **Not a rewrite of the memory API.** `Memory`'s own methods still address
  the default scope, so a program that never mentions a scope behaves exactly
  as it did before. A capability that changes shape under the people using it
  is a different capability.
- **Not importance, and not metadata.** Those are the next candidates — a
  per-entry weight in the retrieval, and a filter over typed fields — and they
  are bigger questions than a partition of the keyspace, so they are the next
  LOOP rather than part of this one.
