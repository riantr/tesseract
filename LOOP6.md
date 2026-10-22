# LOOP 6 — how much an entry counts, and the three things the store used to accept

`LOOP3.md` built the short-term memory, `LOOP4.md` audited it, `LOOP5.md` gave
it scopes. This one adds the last of the three weights the score is made of —
the **importance** — and, on the way, fixes three things the published store
accepted and should not have.

The reason to add a weight and not another feature: the score was already a
product of two, and the third was the one a caller could not supply. A memory
that holds a hundred things needs to say *which* of them matter, and the only
way to say it was to put the answer in the value.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `08b7dc6` (v0.1.7): 301 tests, all green, 36 CLI checks, 45
window checks.

### What a caller could not say

| the caller wanted | v0.1.7 |
|---|---|
| to say that one entry matters more than another | no such thing — every entry weighed the same |
| a lifetime of nothing | accepted, and the entry was born dead |
| a lifetime in the past | accepted, and the entry was born dead |
| a clock moved past the end of time | accepted, and the clock ran backwards |

### The two rules the new shape follows from

1. **The score is a product of three weights**, each a fraction: how alike the
   texts are, how recently the entry was written, and how much the entry
   counts.
2. **The store refuses what it cannot honour**, and the refusal leaves the
   store exactly as it was.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **The importance is a weight in `(0.0, 1.0]`.** One is the default and the
   most an entry can count; a lower number counts less.
2. **Both ends of the range are refused, not clamped.** Zero would make the
   entry unfindable, and above one would carry the score past the range it
   is documented to be in.
3. **A lifetime is at least one millisecond, or "never".** A lifetime of
   nothing is an entry that is dead on arrival, and a write that does nothing
   is a write the store refuses.
4. **An instant that does not fit is not an instant.** The clock refuses to
   move past the end of what an `Int64` can hold, and a deadline saturates
   rather than wrapping into the past.
5. **Whether an entry expires is decided by its window**, not by its
   deadline — because a deadline of zero is also the deadline an entry that
   never expires carries.

---

## The six steps

### Step 1 — `EntrySpec`

The two settings an entry is written with travel together, because they are
written together: `ttl` and `importance`. `default_spec()`, `with_ttl`,
`with_importance`, `is_valid`, and `put_spec` on both the memory and a scope.
`put` and `put_with_ttl` are the two shorthands, so a program that never
mentions an importance is unaffected.

### Step 2 — the importance in the score

`score = similarity × recency × importance`. Each factor is a fraction, so the
score stays in `0.0..1.0` — the range the package has documented since
v0.1.6, and the reason the importance is capped at one.

`Entry` carries the importance and `Hit` reports it, so a caller that wants to
know *why* an entry ranked where it did can see which of the three weights
moved it.

### Step 3 — the refusals

`EntrySpec::is_valid` says whether a spec is one the store can hold, and
`put_spec` refuses the rest **before** anything is touched. A refused write
leaves the store exactly as it was, which is the same rule the byte budget
has had since v0.1.5.

### Step 4 — the instant arithmetic

`instant_after(now, ms)` is a **saturating** add: a deadline that would not
fit in an `Int64` becomes the largest instant there is, rather than wrapping
round into the past. The clock's `advance` **refuses** an interval that would
not fit, because a clock that stops at the end of time is not a clock the
caller can keep using, and one that wraps is worse.

### Step 5 — the window, not the deadline

Whether an entry expires is decided by its window. A deadline of zero is the
deadline an entry that never expires carries, and a store that told those
two apart by the deadline would give a zero-lifetime entry the other one's
meaning: it would live forever.

### Step 6 — the gates

The same gate the module already runs, plus the `cmd/memory` surface:
`put ... --importance N`, and the importance reported with each entry.

---

## Record — what the work actually found

### The clock ran backwards while reporting that it had moved forwards

The rule the package has always had is that the clock moves forward, and a
negative interval has been refused since v0.1.6. But the check was on the
*sign* of the interval, and the arithmetic on the way in was never checked:

```
advance(1000)                      -> clock 1000
advance(Int64::max_value())        -> accepted: true
                                   -> clock -9223372036854774809
advance(Int64::max_value())        -> accepted: true
                                   -> clock 998
```

The clock went backwards by nine hundred million years, and the store said
`true` both times. The harm is not the absurd number: it is that an entry
would then be *older* than the moment it was written, which is the exact
condition v0.1.6 refused a negative interval to prevent.

⇒ **Rule:** an interval is refused when it is negative **and** when the
result does not fit. A sign check is half of a bound check.

### A lifetime of nothing was a write that did nothing

```
put_with_ttl("k", "v", ttl_absolute(-1000))  -> true
get("k")                                      -> None
the store holds                               -> 0 entries
```

The write was reported as done and the value was gone. A store that says
"stored" and does not store is worse than one that refuses, because the
caller has no way to tell the difference.

⇒ **Corollary:** the refusal has to be at the *write*, not at the read. A
refusal that only shows up later is a silent one.

### Zero and the "never" deadline were the same value

The first version of the zero-lifetime rule was to *accept* it and let the
entry be dead on arrival. The test caught something else: at `t=0` with a
zero lifetime, the deadline is `0`, and **a deadline of zero is the deadline
an entry that never expires carries**. The entry would have lived forever.

The fix was not to move the sentinel — the deadline is a public field, and
"zero means never" is what the package has always said. The fix was to
decide expiry by the **window**, which is unambiguous: an entry with no
deadline has a window of zero, and every entry with a lifetime has a window
of at least one millisecond.

⇒ **Rule:** one value, one meaning. A representation that overloads a value
has to be told apart by something else, and the something else is usually
already there.

⇒ **Corollary:** the case where the two conventions differ is a clock before
the epoch — there, the deadline of a one-millisecond entry *is* zero, and
only the window tells it from an entry that never expires. The test that
pins the rule is the one that uses that clock.

### The test that could not fail, a third time

The mutation that put the expiry check back on the deadline **survived** the
whole suite, because the new refusal rule had made the two conventions
agree on every entry the store could actually hold. A mutation that survives
is not always a gap in the implementation: it can be a gap in the *fixture*,
and here the fixture had no case where the two could differ.

The fix was the same move as the last two times: find the case where the
distinction shows — a clock before the epoch — and put it in.

⇒ **Rule:** when two implementations are equivalent over the whole input
space the store can reach, a mutation that swaps them will survive, and the
survival is a statement about the *input space*, not about the mutation. The
question to ask is not "does this test fail when I break the code" but "is
there an input where the two differ at all".

⇒ **Corollary:** the four mutations run against this loop were: the
importance leaving the score (three tests failed), the importance not being
validated (three), the clock overflow check removed (one), and the expiry
convention swapped (one, after the fixture was fixed).

### A float parser, and why it is hand-written

The shell needs to read an importance, and the toolchain has no way to turn a
string into a double — `Double::from_string` and `String::to_double` do not
exist in it. So `parse_float` is written out, next to `parse_int`, with the
same discipline: `None` rather than a silent zero for anything the grammar
does not cover, and a number too long to be exact is refused rather than
rounded.

The grammar is a plain decimal — a sign, digits, a fractional part — and
**no exponent**. `1e3` is not a number here, and saying so is better than
quietly accepting a shape the caller may not have meant.

⇒ **Rule:** a number that is not a number is refused, and a number too long
to be exact is refused too. Both are cases where the alternative is a
silently different value.

### The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   314 passed / 0 failed   (was 301)
cli-smoke.mjs   43 PASS / 0 FAIL   (was 36)
```

`spec_test.mbt` holds 10 tests, and they are the rules: the default
importance, half as strong, a better match turned into a worse one, the two
ends of the range refused, a lifetime in the past refused, a lifetime of
nothing refused, the window rather than the deadline, a lifetime too long to
add, the importance surviving a read, and a spec saying whether it can be
honoured. `memory_test.mbt` gained the clock that cannot pass the end of
time, and the core gained `parse_float` and its test.

---

## What this deliberately does not do

- **Not eviction by importance.** The importance weights retrieval, and the
  eviction policies are about age, use and expiry. Making the eviction rank
  a `Double` would put a rounding decision in the middle of a tie-break.
- **Not a boost.** The default is the maximum, so the range can only demote.
  A caller who wants an entry to outrank the rest keeps it at the default and
  demotes the rest.
- **Not a per-scope importance.** The importance belongs to the entry, and
  the scopes are partitions of one keyspace.
- **Not a negative importance, and not a weight above one.** Both would leave
  the `0.0..1.0` the score is documented to be in.
- **Not persistence.** The memory is still the tier above the durable store.
- **Not thread safety**, for the same reason the core is not.
- **Not a rewrite of the memory API.** `put` and `put_with_ttl` still work
  exactly as they did, and a program that never mentions an importance behaves
  exactly as it did before.
