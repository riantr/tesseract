# LOOP 8 — the pin, and the write that had to be refused

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes, `LOOP6.md` gave it a weight, `LOOP7.md` gave it labels. This one
gives it a **pin**: an entry that is never thrown away to make room for
another one.

The reason to add a pin and not another dimension of scoring: the store can
already say how much an entry counts and what it is labelled, but it had no
way to say *this one must not be lost*. A caller who needed that had to keep
the thing somewhere else — which is the whole thing a memory is for.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `d54c3a4` (v0.1.9): 344 tests, all green, 55 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.9 |
|---|---|
| to keep an entry when the store is full | no such thing — every entry was a candidate for eviction |
| to know that an entry would survive | no such thing — the eviction was decided by a policy and a tie-break |

### The three rules the new shape follows from

1. **A pin is absolute.** A store that broke a pin when it had to would make
   the promise depend on the state of the store, and a caller who pinned an
   entry could not tell from the answer whether the entry had survived.
2. **A pin is about the eviction and nothing else.** It does not make an entry
   immortal, it does not change its score, and it does not make it free.
3. **A refused write changes nothing.** Not one byte, not one entry.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **A pinned entry is not a candidate for eviction at all** — not the oldest,
   not the least used, not the one whose time is up soonest.
2. **A store that cannot make room refuses the write**, and the refusal
   leaves the store as it was.
3. **The room is planned before it is taken.** If even throwing away every
   entry that could be thrown away would not make room, nothing is evicted.
4. **The pin says nothing about expiry.** A pinned entry with a lifetime
   still dies when its time is up.
5. **The pin belongs to the entry.** It survives a read and a touch, and a
   write of the same key replaces it with whatever the new write asked for.

---

## The four steps

### Step 1 — the pin on the entry and the spec

`Entry.pinned`, `Entry::pinned()`, `EntrySpec::with_pinned(true)`, and
`default_spec()` carrying `pinned: false`.

### Step 2 — the pin in the eviction

`pick_victim` skips a pinned entry. The pin is checked **before** the policy
is asked, so it does not matter which of the four policies the store uses.

### Step 3 — the room is planned before it is taken

`can_make_room` asks the best case: if **every** entry that could be thrown
away were thrown away, would the store fit? If it would not, the write is
refused before anything is evicted.

### Step 4 — pinning and unpinning what is there

`Memory::pin`, `Memory::unpin`, `Scope::pin`, `Scope::unpin`. They change
**only** the pin: the age, the hit count, the deadline, the importance and
the labels are all left as they were.

---

## What the measurement found

### The refused write that had already thrown something away

This is the finding of the loop, and it is the reason the loop is more than a
flag.

The eviction loop was: *while the store is over a limit, throw away the
victim*. It gave up when there was no victim — and it gave up **after** it had
already thrown some away. Without a pin that could not happen, because the
only entry the loop would not touch was the key being written, and the loop
always reached a state where the write fitted.

With a pin it can happen, and the shape of the trap is worth writing down.
A store with a 20-byte budget:

```
put "a" = "aaaaaaaa"               (8 bytes, not pinned)   -> 8 bytes
put "b" = "bbbbbbbbbbbb"           (12 bytes, pinned)     -> 20 bytes
put "c" = "cccccccccccc"           (12 bytes)             -> refused
```

The third write does not fit: 20 + 12 is 32, and the budget is 20. The loop
throws "a" away — 8 bytes — and asks again: 12 + 12 is 24, still over. The
only entries left are "b", which is pinned, and "c", which is being written.
There is no victim, so the write is refused.

**And "a" is gone.** The write was refused, the caller was told the write was
refused, and the store had lost an entry the caller never asked to lose. The
package's rule — *a refused write leaves the store as it was* — was broken,
and the breaking of it was silent: the only evidence was an entry that was
not there any more.

The fix is to **plan the room before taking it**. `can_make_room` asks the
best case: if every entry that could be thrown away were thrown away, would
the store fit? Here: 20 − 8 + 12 is 24, which is over the budget, so the
answer is no, and the write is refused with nothing evicted. "a" survives.

⇒ **Rule:** a limit that can be reached only by throwing something away
needs the two steps in the other order. *Can this write be made room for at
all?* then *make the room.* The other order throws things away on the way to
a refusal.

⇒ **Corollary:** this is the same shape as the byte-budget rule the store
already had — "a value larger than the whole budget is refused, even in an
empty store" — applied to the *total* rather than to one value. The store
already refused a write it could not fit; what it did not do was check
whether the write could fit **after** the evictions, before making them.

⇒ **Corollary 2:** the mutation that removes the plan was caught by exactly
one test, and that test is the one that checks the store is unchanged after a
refusal. Every other test in the suite passed with the plan removed. A rule
that is only about the *side effects* of a failure needs a test that is only
about the side effects of a failure.

### A pin is not immortality

The first version of the rule said a pinned entry is never thrown away, and a
test pinned down the eviction. It said nothing about expiry, and the gap was
real: a caller reading "never thrown away" could reasonably expect an entry
that never dies, and an entry with a lifetime would die anyway.

⇒ **Rule:** "do not evict me" and "never die" are two different promises, and
a store that makes the first one has to say that it is not making the second.
The pin is about the **eviction**, and the README says so in as many words.

⇒ **Corollary:** the same is true of the other two things the pin does *not*
do — it does not change the score, and it does not make the entry free. A
pinned entry still takes up room, and a store whose every entry is pinned
cannot take anything else. That is a feature and a trap, and the trap is
visible: the write is refused.

### A pin is absolute, not a preference

The alternative was a **soft** pin: prefer not to throw this away, but do if
there is no other way. It is what several caches do, and it was rejected.

A soft pin makes the promise depend on the state of the store. The same
program, the same writes, would keep the pinned entry on one run and lose it
on another, and the caller would have no way to tell — which is the same
complaint the package has about a key order that depends on the length of
the key, and about a tie-break nobody can predict.

⇒ **Rule:** a promise a caller can rely on is worth more than a promise that
is often kept. The store refuses the write instead, and the refusal is
visible.

⇒ **Corollary:** "absolute" has to mean it in the *arithmetic* as well as in
the prose. The pin is checked before the policy is asked, so no policy can
overrule it — and the test that says so tries all four.

### A pin belongs to the entry, and the store's eviction is the store's

The eviction is the **store's**, not a scope's: the capacity and the byte
budget are spent across every scope, so a write into one scope can evict an
entry from another. A pinned entry in one scope is therefore safe from a
write in another, and that is not a special case — it falls out of the pin
being a property of the entry and the eviction being the store's.

⇒ **Rule:** a property of an entry is honoured wherever the entry lives, and
the scope is not a second store. A pin does not need a scope-level rule,
because there is nothing to add.

### The substring trap, again

The smoke check for `unpin` was `!output.includes("pinned")`, and it failed
against a store that had unpinned the entry correctly — because the command
echoes "unpinned a", and **"unpinned" contains "pinned"**.

⇒ **Rule:** a check on a *word* in an output has to match the whole word, or
the shape the word takes in that output. The check now looks for `", pinned"`,
which is the form the entry's own line takes.

⇒ **Corollary:** the same trap was already set in the smoke file, in the
other direction — a `put` echoes the value it stored, so the value is in the
output whether or not a search found it. The hits are found by the score
they carry, and the entries by the line they are on.

### The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   361 passed / 0 failed   (was 344)
cli-smoke.mjs   65 PASS / 0 FAIL   (was 55)
```

`pin_test.mbt` holds 17 tests, and they are the rules: the pinned entry not
being the one thrown away, the control without the pin, the store of pinned
entries refusing the write, the refused write leaving the store as it was,
the pinned entry still expiring, the pinned entry still being found, the
pinned entry still taking up the room, pinning changing nothing else, pinning
what is not there, unpinning, the pin surviving a touch, the write replacing
the pin, all four policies respecting the pin, the pin in the report, a
scope's pin, the scope's own pin and unpin, and the order of the keys.

---

## What this deliberately does not do

- **Not a soft pin.** A pin is absolute, and a store that cannot make room
  refuses the write rather than breaking it.
- **Not immortality.** A pinned entry still expires when its lifetime is up.
- **Not a free entry.** A pinned entry still counts against the capacity and
  the byte budget.
- **Not a weight.** The pin does not change the score, and the importance
  does not change the eviction.
- **Not a per-scope budget or a per-scope pin.** The pin belongs to the entry
  and the eviction is the store's.
- **Not a counter.** Like a touch, a pin is not a thing the statistics
  count — it is a property of an entry, and the entry is where it is read.
- **Not persistence, and not thread safety**, for the same reasons as before.
- **Not a rewrite of the memory API.** `put`, `put_with_ttl` and `put_spec`
  still work exactly as they did, and a program that never mentions a pin
  behaves exactly as it did before.
