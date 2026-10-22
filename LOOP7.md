# LOOP 7 — the labels on an entry, and the searches that use them

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes, `LOOP6.md` gave it a weight. This one gives it **labels**: the
key/value pairs that say what an entry *is*, as opposed to what it says — and
the **filtered retrieval** that uses them.

The reason to add labels and not another dimension of scoring: a memory that
holds a hundred things does not only need to say how much each one counts
(the importance, `LOOP6.md`), it needs to say **which kind** of thing each one
is. A caller who wants the notes and not the tasks has no way to say so, and
the only way to say it today is to put it in the value — where the search
cannot see it.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `49e4c7c` (v0.1.8): 314 tests, all green, 43 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.8 |
|---|---|
| to say that one entry is a note and another is a task | no such thing — every entry was the same kind of thing |
| to ask a search for the notes and not the tasks | no such thing — the search only ever looked at the text |
| to list the entries of one kind without knowing what they say | no such thing — the only lists were by key |

### The three rules the new shape follows from

1. **A filter is a value, not a call.** It has to be buildable, printable and
   handable to a shell, because a filter is the thing a caller composes.
2. **A filter chooses the candidates, before they are scored.** It says what
   the store may look at, not how what it looked at is ranked.
3. **What the store holds is what the budget counts.** The labels are part of
   the content, so the byte total has to include them.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **The metadata is a set of key/value pairs.** Sorted, with the duplicates
   dropped, and a key may carry several values.
2. **A label with no name is refused.** The key is the name of the label.
3. **The metadata is a value the caller cannot change.** The accessor hands
   out a copy, because an array in this toolchain is shared rather than
   copied.
4. **A filter is applied to the candidates.** The `k` is a limit on the
   answer, not on the candidates.
5. **The labels change neither the score nor the eviction.** They say what an
   entry *is*; they are not a weight.

---

## The five steps

### Step 1 — `Metadata`

`new_metadata(pairs)`, `no_metadata()`, and the accessors: `pairs`, `has`,
`has_value`, `values`, `size`, `is_empty`, `is_valid`, `bytes`, `describe`.

### Step 2 — the labels on an entry

`Entry` carries them and `EntrySpec` writes them: `with_metadata(metadata)`, and
`put_spec` carries them into the store. The spec refuses a label with an empty
key, and the refusal leaves the store as it was.

### Step 3 — the filter

`MetadataFilter` with six cases and six constructors: `filter_has`,
`filter_lacks`, `filter_equals`, `filter_not_equals`, `filter_all`,
`filter_any`, and `matches(metadata)`.

### Step 4 — the filtered searches

`Memory::search_filtered`, `search_filtered_keys`, `search_all_filtered`,
`search_all_filtered_keys`, `entries_filtered`, and the two scope-level ones.
The old searches are the same code with no filter, so they are unchanged.

### Step 5 — the shell

`put --meta k=v`, `search --where k=v`, `--where k`, `--without k`, and
`entries --where ...`. The filters are combined with *and*.

---

## What the measurement found

### An array is shared, not copied

The first question was what to hold the metadata in. A `Map` was out — the
package already knows that a `Map` is mutable in place, which is why
`Memory`'s fields are private. But the same is true of an `Array`, and it was
worth measuring rather than assuming:

```
let a = [1, 2, 3]
let b = a
b.push(4)
a.length()   ->  4
```

The array is **shared**. So a `Metadata` that handed out its own array would
be handing out the ability to change the entry behind the store's back — the
same hazard the private fields of `Memory` exist to prevent, one level down.

⇒ **Rule:** a value the store holds and the caller can reach is not held
safely unless the accessor hands out a **copy**. `Metadata::pairs` returns
`self.pairs.copy()`.

⇒ **Corollary:** the probe also showed that the fields of a **non-public**
struct are private by default — `priv` on them is a warning, not a modifier.
In a `pub struct` the fields are public unless marked `priv`, which is why
`Entry`'s fields are readable and `Metadata`'s are not.

### The test that could not fail, a fourth time

This loop's mutation that matters most is the one that **survived**.

The rule under test was "the filter chooses the candidates, and the limit
chooses the answer". The mutation was to score everything, sort, cut to `k`,
and *then* turn the losers away. A store that does that gives back **nothing**
when the best match is one the filter turns away — so the rule is real and the
answer is visibly different.

The mutation **survived the whole 344-test suite.** The reason was the
fixture, and it is the same reason the last three times: the case was too
kind.

The old test had two entries and asked for `k = 2`. Filter the candidates and
cut to two, or cut to two and filter, and both answers were the same — the
`k` was never smaller than the number of entries, so the *order* of the two
steps could not show.

⇒ **Rule:** a test that checks **where** a step happens needs a case where
the two orders differ, and the difference is usually in the *size* of the
answer rather than in its contents.

⇒ **Corollary:** the case that shows it is a filtered-out entry that is the
**best match of all**, with `k` smaller than the number of candidates. Then
the correct store answers with the best entry it was *allowed* to look at,
and the wrong one answers with nothing. The new test builds exactly that:
three entries, the best of them turned away, `k = 1`.

⇒ **Corollary 2:** the six mutations run against this loop were: the filter
ignored (five tests failed), the filter applied after the cut (one, after the
fixture was fixed), the labels not counted in the budget (one), the labels
dropped on a touch (one), an empty `All` not holding (one), and the pairs not
sorted (two).

### The budget has to count the labels

The byte budget was "the size of the **values**". The moment an entry can
carry labels, that sentence is a lie: the memory holds the labels, and
`size_bytes` does not count them.

The choice was between two answers. Counting the labels changes what
`size_bytes` means; not counting them leaves the budget measuring only part
of what the store holds.

⇒ **Rule:** the budget counts **the content of an entry** — its value and its
labels. The key and the scope are not counted, because they are the *name* of
an entry rather than its content, and the capacity bounds how many entries
there are.

⇒ **Corollary:** this is invisible to anyone not using the new feature. An
entry with no labels has none, so the number does not move — the change is
safe in a patch release in a way that "the budget means something else now"
would not have been.

### A shell flag that meant something else

`--without kind=task` was implemented as "the entry does not have a label
called `kind=task`" — the whole argument was used as the key, and the `=` was
never split. Every entry passed, because no entry has a label with that name.

It was found by driving the CLI by hand, not by a test, and the fix was to
make `--without` the exact mirror of `--where`: `k=v` asks for the label `k`
**not** to carry the value `v`, and a bare `k` asks for the label `k` to be
absent.

⇒ **Rule:** a flag that takes a compound argument has to be parsed by the
*same* rule on both sides of the pair. One that splits and one that does not
is a flag that means something nobody wrote.

⇒ **Corollary:** the first version of the smoke check for this was itself
wrong, and wrong in the direction that hides bugs. It asserted
`!output.includes("the cat ran")`, and the output *did* contain "the cat ran"
— in the **echo of the `put` that wrote it**. A `put` echoes the value it
stored, so the value is in the output whether or not the search found it.

⇒ **Corollary 2:** the check has to look at the *hits*, not at the output. A
hit line carries a score and a `put` line does not, so the score is what says
"this line is a result". The smoke test now filters on it, and the checks
count the hits rather than searching for text.

### What an empty list means

An empty `All` **holds** and an empty `Any` does not. Nothing was asked, so
nothing was missed; nothing was asked, so nothing was found.

It is the ordinary reading, and it is the reading that keeps `filter_all([])`
usable as "no condition" — but it was worth a test of its own, because the
other reading is possible and a mutation between them survives if nothing
pins it. It did not: the mutation was caught.

⇒ **Rule:** a vacuous truth is a rule, and a rule that is not written down is
a rule that will be implemented the other way round by the next person.

### A key with no name

A pair with an empty key is refused. The key is the *name* of the label, and
a label with no name cannot be selected by any filter a caller would write
("has" a label called ""), and in a report it renders as `=value`, which says
nothing.

A pair with an empty **value** is fine: "the kind is nothing" is a thing a
caller can say, and it renders as `kind=`.

⇒ **Rule:** the name of a thing is part of the thing. A record with no name is
not a record, and the store refuses it rather than holding something that
cannot be reached.

⇒ **Corollary:** the same rule is why the CLI refuses `--meta =value` with
"the label needs a name" rather than storing it.

---

## The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   344 passed / 0 failed   (was 314)
cli-smoke.mjs   55 PASS / 0 FAIL   (was 43)
```

`metadata_test.mbt` holds 30 tests, and they are the rules: the empty
metadata, the order, the duplicates, the copy, the empty key refused, the
refusal leaving the store alone, the labels on an entry, the labels in the
byte count, the six filters, the empty list, the filtered searches, the score
not changing, the answer not being padded, the scopes, the eviction not
changing, the labels surviving a touch, and the replacement taking the old
labels out of the count.

---

## What this deliberately does not do

- **Not eviction by the labels.** The labels say what an entry is, and a filter
  says what a search may look at. Neither is a weight, and a store that
  evicted by them would make the eviction depend on a field nobody promised
  anything about.
- **Not a boost, and not a score change.** The filter chooses the candidates
  and the similarity, the recency and the importance still rank them.
- **Not a value type.** The labels are strings, because the store holds
  strings and the search matches on strings. A caller who needs a number in a
  label can put it in the value.
- **Not a query language.** The filter is a value with six cases. The shell
  exposes three of them; the library has all six.
- **Not a per-scope label set.** The labels belong to the entry, and the
  scopes are partitions of one keyspace.
- **Not persistence, and not thread safety**, for the same reasons as before.
- **Not a rewrite of the memory API.** `search`, `search_all` and `search_keys`
  still work exactly as they did, and a program that never mentions a label
  behaves exactly as it did before.
