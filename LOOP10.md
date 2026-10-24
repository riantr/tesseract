# LOOP 10 — the kinds, and the entry that takes the most room

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes, `LOOP6.md` gave it a weight, `LOOP7.md` gave it labels, `LOOP8.md`
gave it a pin, `LOOP9.md` gave it a checkpoint. This one gives it **kinds** and
a fifth **eviction policy**.

The reason to add both in one loop: they are the same observation. A store that
holds different kinds of thing holds entries of different *sizes*, and once the
sizes differ the policies that compare time or use stop being the interesting
question — the interesting question is which entry takes the most room.

---

## What the baseline actually is

Measured against `17d4135` (v0.1.11): 376 tests, all green, 80 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.11 |
|---|---|
| to ask a memory what kinds of thing it held | no such thing — the labels were per entry and nothing listed them |
| to throw away the entry that takes the most room | no such thing — the four policies compared age, use and expiry, never size |
| to write an entry *as* a kind | possible, by hand: `new_metadata([("kind", "task")])` — but the store had no idea kinds were a thing |

### The two rules the new shape follows from

1. **A kind is a label.** It is the value of the `kind` label and nothing
   else: not a new field on an entry, not a new type of entry, and not a new
   storage format.
2. **The largest entry is the one that goes** when the policy is asked for the
   biggest, and the size is the one the byte budget counts.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **The kind is one value.** A metadata that already carried a kind is given
   the new one rather than carrying both, and a kind with no name takes the kind
   away rather than writing an empty one.
2. **The kinds are derived, not stored.** Nothing extra is kept, so the answer
   to "what kinds do you hold?" is the answer about the entries themselves.
3. **An entry of no kind is of no kind.** It is not counted, and it is not
   listed — and it is not an error either.
4. **The kind does not decide what goes.** The labels say what an entry *is*;
   the eviction policy says what goes, and the policy is not the kind.
5. **The size is the room an entry takes**: the value and its labels, the same
   thing the byte budget counts.

---

## The four steps

### Step 1 — the kind is a label

`KIND_LABEL`, `Metadata::with_kind`, `Entry::kind`. Nothing else: the entry
still carries metadata, and the kind is the value of one pair in it.

### Step 2 — the store's report of its composition

`Memory::kinds`, `Memory::entries_of_kind`, and the same two on a scope. The
counts are derived from the labels on every call — there is no index of kinds
and nothing to keep in step with the entries.

### Step 3 — the fifth policy

`evict_largest()`. The victim is the entry that takes the most room.

The store evicts the entry with the **smallest** rank, and the other four
policies rank so that the worst entry has the smallest rank: the most recently
used, the most often read, the closest to expiring, the oldest. This one wants
the **largest** entry, so its rank is the *negative* of the size. Every policy
then compares the same way, and a policy that wanted the opposite would need a
second comparison rather than a second rank.

### Step 4 — the shell

`put --kind K`, the `kinds` command, and `--kind K` on `entries` and `search`
as a spelling of `--where kind=…`.

---

## What the measurement found

### The size is the room an entry takes, and that is not the same as the value

The first version of the policy ranked by the **value's** bytes, which is the
obvious thing to write down. The mutation that caught it was not a mutation of
the policy but of its *size*: an entry with a short value and a long label is
the bigger entry, because the budget counts the labels.

The labels are part of the content — that is not new, and the byte budget has
counted them since `LOOP5.md` — but the policy is the first thing that
compares two entries **by their size**, so the size had to be the one the
budget counts rather than the one that was easiest to write.

The fixture that catches it is two entries whose *values* differ in the
opposite direction from their *sizes*:

```moonbit
ignore(m.put("a", "a value of five"))
ignore(m.put_spec("b", "x", ...with_metadata([("kind", "a-longer-kind")])))
```

`b` has the shorter value and the larger entry, and `b` is the one that goes.

### The tie-break had to be pinned for the new policy too

Every policy breaks a tie the same way — by scope, then by key — and the
existing test for that used `evict_oldest`. The tie-break is shared code, so
one test would have covered it. But the *rank* is new, and a rank that ties is
a rank the tie-break has to break: two entries of the same size are a tie, and
the policy has nothing else to go on. So the new policy has its own tie test.

### The pin test was carrying a rule without saying so

`pin_test.mbt` has a test called "every eviction policy respects the pin", and
it listed four policies. A fifth policy that was not on the list would not have
been pinned by it — the test would have kept passing while saying "every" about
four of the five. The list is now complete, and the test says what it says.

### The kinds came out in the order they were written in

The first version of the report listed the kinds in the order the entries
happened to be written. The store's other reports are sorted — the keys are in
key order, the scopes are in name order — and a report that answers differently
depending on the order of the writes is a report nobody can test. The kinds are
now sorted by their letters, and there is a test that fills two stores in
opposite orders and checks they answer the same.

---

## The numbers

| | v0.1.11 | v0.1.12 |
|---|---:|---:|
| tests | 376 | **388** |
| CLI checks | 80 | **87** |
| window checks | 45 | 45 |
| eviction policies | 4 | **5** |

Twelve tests and seven CLI checks. The mutations: the size policy picking the
smallest, the size ignoring the labels, `with_kind` keeping the old kind
beside the new one, and the kinds coming out in the order of the writes. All
four were caught.
