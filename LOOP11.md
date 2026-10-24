# LOOP 11 — the SQL index, and the rebuild that proves it is derivative

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes, `LOOP6.md` gave it a weight, `LOOP7.md` gave it labels, `LOOP8.md`
gave it a pin, `LOOP9.md` gave it a checkpoint, `LOOP10.md` gave it kinds. This
one gives it an **index** — and a rebuild that says, in numbers, that the index
is not the store's twin but the store's shadow.

The reason to add it in this loop: the memory could hold a hundred entries and
answer a *similarity* question about them, but it could not answer "which of my
entries say `cat`?" without reading every one of them. That is a lookup, and
the memory had no lookup for it.

---

## What the baseline actually is

Measured against `4647678` (v0.1.12): 388 tests, all green, 87 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.12 |
|---|---|
| to ask which entries contain a given word | no such thing — `search` is a similarity, and an entry that shares nothing with the query is not in its answer |
| to ask that question without reading the whole store | no such thing — every entry was a scan |
| to see the answer in SQL | no such thing — the index did not exist |
| to know whether a search index was still in step with the store | no such thing — there was no index to be out of step |

### The three rules the new shape follows from

1. **The index is SQL.** It is a plain table in a SQLite file, so it is a table
   a person can query — not an API that happens to be fast.
2. **The index is derivative.** Every row is a word of an entry's value or of
   one of its labels, so the index holds nothing the entries do not: it can be
   thrown away and built again, and the rebuild gives back the same thing.
3. **The rebuild is explicit and it reports.** It says how far the index was
   from the store, and a rebuild of an index that was already right says
   nothing at all — which is the proof of rule 2.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **One row per word, per entry.** The table is
   `tesseract_memory_index(token, scope, key)`, and the key is all three.
2. **The words are the content's words.** The words of the value, and the words
   of the **values** of the labels. The *keys* of the labels are not words:
   "kind" is the name of a label, and every entry with a kind would then be
   found by the word "kind", which says nothing about the entry.
3. **The lookup is exact.** The memory's own search is a similarity; this is
   not that. "cat" finds the entry that says "cat", and "ca" and "cats" find
   nothing. The query is lowercased, because the index holds the words the
   tokenizer wrote and the tokenizer lowercases.
4. **A verify changes nothing.** It is the rebuild's question asked without the
   answer, and it does not even create the file it was asked about — a read
   that wrote would be a read that lied.
5. **The store decides.** The rebuild reads the store's own scopes and entries,
   so the index covers the whole store, and an entry the store has forgotten or
   let die has no rows.

---

## The three steps

### Step 1 — the index

`src/tesseract_memory_index`: `MemoryIndex`, `open`, `rows`, `lookup`, `put`,
`forget`, `rebuild`, `verify`.

It is a **separate package** because the file is a `.db`, and the `.db` adapter
builds for `native` and `wasm` only — the same reason `src/tesseract_memory_db`
is separate, and the same reason `cmd/memory_db` is a separate binary from
`cmd/memory`. The memory tier itself stays on all four backends.

### Step 2 — the rebuild, and the report

`rebuild` puts the index back in step with the store and says what it had to
change: the entries that changed, the rows to add, the rows to remove. A
rebuild of an index that was already right changes **nothing** and says so.

`verify` is the same question asked without the answer. It computes the same
diff and applies none of it.

Both are one transaction, so the index is never half-rebuilt: a reader sees the
index it had or the index the store says, not something in between.

### Step 3 — the shell

`cmd/memory_db --index PATH` takes the index path out of the arguments before
the shared command layer sees them — the index is that binary's own business,
and `cmd/memory` must keep every backend it has.

`index` rebuilds and reports. `index-find <word>` looks a word up. The index
is **not** rebuilt by the other commands: a command that changes the store
changes the store, and the index is the caller's to rebuild when it wants it
fresh. So `index-find` checks the index against the store before it answers,
and says so when the two disagree.

---

## What the measurement found

### The counts could not be `Int32`

`RebuildReport` counts four things, and the first version made them `Int32`.
`Int64::to_int32` does not compile in this toolchain, and neither does
`Int32::to_int`, and `Array` is indexed by `Int` — so `Int32` is a dead end in
both directions from where the counts come from. The counts are `Int`. The core
already said this in `src/tesseract/coords.mbt`, and the lesson was written
down there before this package existed.

### The row count cannot tell a repair from a drift

The rule "a verify changes nothing" was first checked by the **number of rows**
in the file. That does not work: a repair leaves the same number of rows as
the drift it fixed, because the repair takes one row away and puts another
back. A verify that quietly repaired the file would have passed that check.

The mutation that proved it — `verify` calling the rebuild with the apply flag
set — survived the first version of the fixture. The house rule for a surviving
mutation is that the **fixture** is what is wrong, and the fixture now looks at
*which* rows are there: the row that was taken away is still away, and the row
that was put in is still in.

### The query has to be normalised, and it is easy to forget

The index holds the words the tokenizer wrote, and the tokenizer lowercases. A
lookup that did not lowercase the query would find "cat" but not "Cat" — and
the store's own `search` is case-insensitive, because it tokenises the query
too. The two ways of asking the same question have to answer the same way.

### The key of a label is not a word

The first version of the token list took the label's **value** and stopped. The
mutation that caught the alternative — the label's *key* counted as a word as
well — is the rule the package documents: "kind" is the name of a label, and
every entry with a kind would then be found by the word "kind".

### A read that writes is a read that lies

`verify` asks whether the index is in step with the store. If the file is not
there, the honest answer is "the index holds nothing, and here is what the
store would put into it" — and the file should still not be there afterwards.
So `verify` asks whether the file exists *before* it opens it, and a file that
is not there is answered without being created. The mutation that removed the
check was caught by the file's absence, not by the report.

---

## The numbers

| | v0.1.12 | v0.1.13 |
|---|---:|---:|
| tests | 388 | **401** |
| CLI checks | 87 | **99** |
| window checks | 45 | 45 |
| library packages | 7 | **8** |

Thirteen tests and twelve CLI checks. The mutations: the label's key counted
as a word, the label's value not counted, the stale rows not removed, the
rebuild reporting without applying, the rebuild applying without reporting,
the lookup not lowercasing, the lookup matching substrings, `put` adding
without taking away, the rebuild covering only the default scope, the rebuild
always reporting a change, the stale scan counting rows instead of entries,
`forget` leaving the rows behind, and `verify` creating the file it was asked
about. All thirteen were caught.
