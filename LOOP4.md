# LOOP 4 — the memory tier, audited: characters it did not expect

`LOOP3.md` built the short-term memory: TTL, capacity eviction, similarity
retrieval, and then a byte budget on top. This one audits what was published
— v0.1.5, 276 tests, all green — and fixes what the audit found.

The reason to audit a released capability rather than build another one: a
capability that is only correct for the text nobody tested is half a
capability, and the tests that were written are the reason the gaps were not
noticed. Everything below was found by *re-reading* the code and *measuring*
it, not by a failing test — which is the part worth recording.

This file is the plan and the record. The measured numbers below are the
acceptance criteria.

---

## What the baseline actually is

Measured against `07526e4` (v0.1.5), with an independent audit of the twelve
invariants the package claims.

### Ten of the twelve invariants held. Two did not.

| | verdict |
|---|---|
| deadline boundary, eager expiry, the eviction order, the tie-break, the clock being a value, a search not being a use, the recency weight | hold |
| the byte total being exact | holds **through the API**, and did not hold through the published interface |
| the byte budget being a hard limit | held for a budget above zero, and the **constructor** did not validate what `set_config` refused |

### An emoji was not a character

A character outside the basic plane is **two code units** in the runtime's
string and one character to a reader. `Int32::to_char` refuses a surrogate,
because half a character is not a character — and the core's `write_cu`
dropped anything `to_char` refused.

So the character was dropped on the way into every text helper:

```
lower("🍎")            -> ""          (both halves dropped)
slice("🍎", 0, 2)      -> ""
tokenize("🍎")         -> []          no words at all
jaccard("🍎", "🍎")     -> 0.000       a text is not similar to itself
tokenize("a🍎b")       -> ["ab"]      the dropped emoji MERGED two runs
```

That last one is the worst of the five. The dropped character did not leave a
gap; it left a **word that was never in the text**.

And it was not only the memory tier. The same helpers are the SQL literal
scanner and the three exporters, so the corruption reached the whole store:

```
SELECT upper('a🍎b')   -> "A??B"       the literal, at parse time
export_tsr             -> "??"
export_markdown        -> "??"
export_sql             -> "??"
```

Any value inserted through SQL with an emoji in it was corrupted before it
was ever stored, and any value *already* stored was corrupted on the way out.

### A limit that the caller could switch off

`set_config` refused a negative byte budget, and said why: a negative number
"would otherwise read as the one value that means no limit at all". The
constructor did not:

```
new_memory_with(default_config().with_max_bytes(-1L))
  -> max_bytes() == -1
  -> a 40-byte value is accepted, with no budget at all
```

The rule existed on one path and not on the other, which is the same shape as
the byte-budget bug the previous LOOP found: **a limit enforced on one write
path and not the other**.

### A total that could drift

`Memory`'s fields were public, and a `Map` is mutable in place. From another
package:

```
put("a","12345"); put("b","67890")   -> size_bytes() == 10
m.entries.remove("a")                -> the store holds 5
                                     -> size_bytes() STILL says 10
```

The byte total is a running count, so a caller who removed an entry behind
the store's back left the count counting something that was no longer there —
and it never recovered, so every later write evicted entries that would have
fitted.

### A clock that ran backwards

`advance` took any number, including a negative one. An entry would then be
*older* than the moment it was written, the recency weight `0.5 ^ (age /
half_life)` came out **larger than one**, and a search score came out at
`2.0` — outside the `0.0..1.0` that `Hit::score` is documented to be in.

---

## The shape of the thing

Five rules, and everything below follows from them.

1. **A character is copied whole.** Half a character is not a character, and a
   helper that copies code units one at a time does not know it has lost one.
2. **A limit is a claim about the store's state after every operation** — so
   it is enforced on every path, and the store cannot be edited behind its
   own back.
3. **A configuration is either usable or it is refused.**
4. **A clock moves forward.**
5. **A test that cannot fail is not a test.** The search test asserted a
   counter that stays zero whether or not the search touched anything.

---

## The six steps

### Step 1 — one primitive for characters

`char_at(s, i) -> (Char, Int32)`: the character at `i`, and the index just
past it. A surrogate pair is put back together; a half-pair is a question
mark. Every text helper, the lexer, the three exporters and the memory's
tokenizer use it, so there is exactly one place where the rule lives.

### Step 2 — the text helpers

`lower`, `upper` and `slice` copy characters rather than code units. The
*folding* stays ASCII-only on purpose — a case rule for a character outside
ASCII is a much bigger question than a SQL keyword needs — but the
*characters* are all kept now. A range is still in code units, and a
character cut by the range is not included: there is no such thing as half a
character.

### Step 3 — the lexer and the exporters

The SQL literal scanner, the backtick identifier, the JSON escaper, the
Markdown escaper and its inverse, the SQL literal escaper, the Markdown row
splitter and the SQL comment stripper. Seven places, one shape.

### Step 4 — the memory's tokenizer and its byte counter

A character outside the basic plane is one word, and it is four UTF-8 bytes.
The byte counter now asks the character's own code point how many bytes it
takes, rather than walking code units and guessing.

### Step 5 — the limits

The configuration is checked at every way in: `Config::is_valid` says whether
a configuration is one a memory can hold; a **new** memory replaces the
setting it cannot use (it has no entries to protect) and a **running** memory
refuses it and keeps the old one (it has entries, and a limit that changed
under them would throw them away). `Memory`'s fields become private, so the
map cannot be edited from outside the package at all. `advance` refuses a
negative interval, and the recency weight is clamped to one for an age that
is not positive.

### Step 6 — the gates

The same gate the module already runs, plus the `cmd/memory` flags that
cannot be honoured now say so instead of being quietly replaced.

---

## Record — what the work actually found

### The bug had one shape, in seven places

Every instance was the same mistake: **copying a string a code unit at a time
and assuming a code unit is a character**. The core's `write_cu` was the
original, and it had been right there since the port — it drops what
`Int32::to_char` refuses, which is exactly the rule that destroys a
surrogate pair.

What made it hard to see is that the damage is *invisible in the output*. An
emoji became two question marks, which is a plausible-looking string. The
clue was not in the text at all; it was in the **arithmetic**: `jaccard("🍎",
"🍎")` is 0.000, and a text that is not similar to itself is a number that
cannot be true. A test that had asked "is this text like itself?" would have
caught the whole family.

⇒ **Rule:** when a store holds text, the first question is what happens to a
character it was not written for. The unit that "length" counts is not the
unit a character is.

⇒ **Corollary:** a helper that returns a *string* built from code units is
not a helper that copies text. It copies code units, and it says so nowhere.

### The test that could not fail

`"a search does not count as a use"` asserted `stats().gets == 0`. That
counter stays zero whether the search touched every entry or none of them,
because a search is not a *get* either way. The test passed against code
that did the opposite of what it claimed.

The test now asserts what the rule is actually about: `last_seen` and `hits`
are unchanged. The rule is about the entry, and the entry was never looked
at.

⇒ **Rule:** a test must assert on the thing the rule is about. A counter
that moves for other reasons cannot tell a rule that holds from a rule that
is not being applied.

### A limit is only a limit if what it limits cannot be edited from outside

The byte total was correct as long as the two mutators were the only ways in.
They were — *inside the package*. The map was public, and `Map::remove`
mutates in place, so the guarantee held only for callers who behaved.

The fix is structural rather than careful: `Memory`'s fields are private.
The published interface is the methods and nothing else — and that is the
first thing worth checking about a store, because a limit over a container
the caller can reach is a limit over the caller's good behaviour.

⇒ **Corollary:** MoonBit's `priv` on a field is narrower than "private to the
package" — a blackbox test file cannot see it either, which is why the
internal consistency of the byte total is checked through the public API
rather than against the map.

### "Half a character is not a character" is a rule, not an excuse

A lone surrogate — one half of a pair with no other half — cannot be
represented. It comes back as a question mark, which is the only thing that
can be done with it, and it is the one place where the length of a string can
change. Everything else keeps its length exactly.

The alternative — dropping it — was what the old code did, and it made a
string *shorter* without saying so. A question mark is at least visible.

### The gates

```
fmt 0   check 0 (wasm, js, native, wasm-gc)
moon test   284 passed / 0 failed   (was 276)
cli-smoke.mjs   26 PASS / 0 FAIL   (was 24)
```

`memory_test.mbt` holds 41 tests, and the four the audit asked for are the
ones that would have caught the four defects: the configuration a memory is
given, the byte total over multibyte values, the score range, and the clock
that purges.

---

## What this deliberately does not do

- **Not a Unicode library.** The case folding is still ASCII-only, on
  purpose: a case rule for a character outside ASCII is a much bigger
  question than a SQL keyword needs, and the port made the ASCII choice
  deliberately.
- **Not a grapheme-cluster library.** A base character and its combining
  marks are two characters here, not one. A cluster is a display question,
  and this is a store.
- **Not a fix for the half-character case.** A lone surrogate becomes a
  question mark. It cannot be anything else.
- **Not a rewrite of the memory tier.** The API is the one that shipped, plus
  `Config::is_valid` and `char_at`. A capability that changes shape under
  the people using it is a different capability.
- **Not a new capability.** This LOOP is about the ones that are already
  published. The audit was the point: the next one should be chosen by what
  a caller still cannot express, not by what is easy to add.
