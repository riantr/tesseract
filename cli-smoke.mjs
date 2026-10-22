// End-to-end smoke test for the two CLIs.
//
//   node cli-smoke.mjs
//
// Builds both binaries for `native` and drives them as real processes, so this
// covers the argv handling and the persistence path rather than the library,
// which `moon test` already covers. The window has `gui-smoke.mjs`; these two
// binaries had no gate at all, which is how `.open sudoku.db` could fail to
// open and `.export md` could quietly write an .tsr file under a .md name.
//
// Every argument here is passed as its own argv entry, the way a shell splits
// it. That is the whole point: a command and its argument reach the program as
// two strings, and matching only the joined form is what broke both CLIs.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = path.dirname(fileURLToPath(import.meta.url));

const log = (...a) => console.log(...a);
const head = (s, n = 4) => (s || "").split(/\r?\n/).slice(0, n).join(" / ");

let failures = 0;
function check(name, got, want, extra) {
  const ok = got === want;
  if (!ok) failures++;
  log(
    `${ok ? "PASS" : "FAIL"}  ${name}` +
      (ok
        ? ""
        : `\n        got:  ${JSON.stringify(got)}\n        want: ${JSON.stringify(want)}` +
          (extra ? `\n        ctx:  ${head(extra, 6)}` : "")),
  );
}

function moon(args) {
  const r = spawnSync("moon", args, { cwd: ROOT, encoding: "utf8", shell: true });
  if (r.status !== 0) throw new Error(`moon ${args.join(" ")} failed:\n${r.stdout}\n${r.stderr}`);
}

function exe(pkg) {
  const p = path.join(
    ROOT,
    "_build",
    "native",
    "debug",
    "build",
    "cmd",
    pkg,
    process.platform === "win32" ? `${pkg}.exe` : pkg,
  );
  if (!fs.existsSync(p)) throw new Error("missing binary: " + p);
  return p;
}

function run(pkg, args, cwd) {
  const r = spawnSync(exe(pkg), args, { cwd, encoding: "utf8" });
  return { out: r.stdout || "", err: r.stderr || "", code: r.status };
}

const SQL_ADD =
  "INSERT INTO tesseract (key,value,digit) VALUES ('u_probe','v1',1) AT 1;";
const SELECT_ALL = "SELECT * FROM tesseract;";

// `  时间: 2026-10-16T12:02:35.886Z` under the wall clock, `  时间: 7` under
// the logical counter. Capturing `\d+` instead of `\S+` looked harmless and was
// not: it truncated the ISO form to the year, so two stamps written a second
// apart compared *equal* and the check that A's stamp was restored into B passed
// for the wrong reason.
const stampOf = (out, key) => {
  const m = new RegExp(key + "[\\s\\S]*?时间:\\s*(\\S+)").exec(out);
  return m ? m[1] : null;
};

// ISO-8601 UTC at a fixed width sorts correctly as a string, which is what
// makes the wall-clock stamps comparable at all. The logical counter is a plain
// integer. `Number()` is wrong for both in different ways - NaN for ISO - so the
// two regimes are told apart explicitly and a mixed pair is refused rather than
// compared across.
const ISO_STAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const is_iso = (s) => s !== null && ISO_STAMP.test(s);

function stamp_after(later, earlier) {
  if (later === null || earlier === null) return false;
  if (is_iso(later) !== is_iso(earlier)) return false;
  return is_iso(later) ? later > earlier : Number(later) > Number(earlier);
}

function main() {
  log("building cmd/main, cmd/persist and cmd/memory for native...");
  moon(["build", "cmd/main", "--target", "native"]);
  moon(["build", "cmd/persist", "--target", "native"]);
  moon(["build", "cmd/memory", "--target", "native"]);

  // A scratch directory this script owns outright, so it can clean up after
  // itself without touching anything of yours.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tesseract-cli-"));
  try {
    // ---- cmd/main: a command and its format arrive as two argv entries ----
    let r = run("main", ["INSERT INTO tesseract (key,value) VALUES ('a','1') AT 5;", ".export", "md"], dir);
    // Pre-fix, bare `.export` exported the default format and `md` ran as SQL.
    check("`.export md` exports Markdown, not the default format", r.out.startsWith("# Tesseract 4D"), true, r.out);
    // Both streams: once `.export` has run it sends everything else to stderr,
    // so the failed parse of `md` would not show up in stdout at all.
    check("`.export md` does not run `md` as SQL", (r.out + r.err).includes("Unsupported SQL statement"), false, r.out + r.err);

    r = run("main", [".export", "sql"], dir);
    check("`.export sql` exports a SQL dump", r.out.startsWith("-- Tesseract 4D export"), true, r.out);

    r = run("main", [".export"], dir);
    check("`.export` on its own still defaults to .tsr", r.out.trimStart().startsWith("{"), true, r.out);

    // ---- cmd/persist: `.open` takes a path, and it is a separate argv entry ----
    const xdb = path.join(dir, "x.db");
    r = run("persist", [".open", "x.db"], dir);
    check("`.open x.db` opens the file", r.out.includes("opened x.db"), true, r.out + r.err);
    check("`.open` no longer falls through to the SQL parser", r.out.includes("Unsupported SQL statement"), false, r.out + r.err);

    r = run("persist", [".open", "x.db", SQL_ADD, ".save"], dir);
    // Pre-fix, `.save` had no path because `.open` never succeeded, so this
    // warned instead of writing - which is how a "saved" run left no file.
    check("a bare `.save` writes back to the file `.open` took", r.out.includes("saved 1 record(s) to x.db"), true, r.out + r.err);
    check("that save produced a non-empty file", fs.existsSync(xdb) && fs.statSync(xdb).size > 0, true);

    // `.save`'s argument is optional, so a following command must not be eaten
    // as the path. A join that ignored this would write a file named `.status`.
    r = run("persist", [".open", "x.db", ".save", ".status"], dir);
    check("a bare `.save` does not swallow the `.status` after it", fs.existsSync(path.join(dir, ".status")), false, r.out + r.err);
    check("...and `.status` still reports", r.out.includes("records : 1"), true, r.out + r.err);

    // ---- timestamps survive a real process boundary ----
    r = run("persist", [".open", "x.db", SQL_ADD, SELECT_ALL, ".save"], dir);
    const stampedA = stampOf(r.out, "u_probe");
    check("process A stamped the cell", stampedA !== null, true, r.out);

    // B advances its own log counter *before* opening, because the load happens
    // inside `.open` and there is otherwise nothing to separate the two paths:
    // both processes would mint the same stamp for the same operation sequence
    // and the check would pass whether or not the file's stamp was restored.
    r = run(
      "persist",
      [SELECT_ALL, SELECT_ALL, SELECT_ALL, SELECT_ALL, SELECT_ALL, ".open", "x.db", SELECT_ALL,
       "INSERT INTO tesseract (key,value,digit) VALUES ('u_marker','m',0) AT 37;", SELECT_ALL],
      dir,
    );
    const loadedB = stampOf(r.out, "u_probe");
    const markerB = stampOf(r.out, "u_marker");
    check("a reopened cell keeps the stamp the file was saved with", loadedB, stampedA, r.out);
    // `cmd/persist` runs on the host clock, so a persisted stamp is an instant
    // rather than a counter. Pinned rather than assumed: if this ever reads a
    // logical counter again, the comparison below silently changes meaning.
    check("a saved stamp is a wall-clock instant", is_iso(stampedA) && is_iso(markerB), true, "A=" + stampedA + " B=" + markerB);
    // The perturbation check: if B's own stamp had not actually moved past the
    // saved one, the line above would hold for the wrong reason.
    check("B's stamp really had moved past the saved one", stamp_after(markerB, stampedA), true, "A=" + stampedA + " B=" + markerB);

    // ---- cmd/memory: the short-term memory tier ----
    // The library's own tests cover the rules; this covers the *shell* around
    // them, which is where a memory's problems actually show up: an argument
    // that arrives mangled, a flag that is swallowed by a value, and a command
    // that has to run against one shared store.
    //
    // The arguments go through `run` as their own argv entries, the way a
    // shell splits them. A JSON value with quotes in it is the interesting
    // case: it is exactly what a shell is worst at, and it is the case that
    // would silently store the wrong text.
    r = run("memory", ["--manual-clock", "put a {\"name\":\"ada\",\"age\":36}", "get a"], dir);
    check("a JSON value reaches the store intact", r.out.includes('{"name":"ada","age":36}'), true, r.out + r.err);

    r = run("memory", ["--manual-clock", "put a hello --ttl 1000", "get a", "advance 1000", "get a"], dir);
    check("a value is there before its TTL is up", r.out.includes("a -> hello"), true, r.out + r.err);
    check("and gone after", r.out.includes("a -> (nothing)"), true, r.out + r.err);

    // A flag must not end up inside the value.
    r = run("memory", ["put greeting hello world --ttl 1000", "get greeting"], dir);
    check("a flag is not part of the value", r.out.includes("greeting -> hello world"), true, r.out + r.err);

    r = run("memory", ["--capacity", "2", "put a 1", "put b 2", "put c 3", "keys"], dir);
    check("the store stays at its capacity", r.out.includes("b, c"), true, r.out + r.err);

    r = run("memory", ["--by", "structure", 'put a {"name":"ada","age":36}', 'put b {"name":"alan"}', 'search {"name":"x"}'], dir);
    check("a search ranks by the similarity it was told to use", r.out.includes("b  1.000"), true, r.out + r.err);

    r = run("memory", ["frobnicate"], dir);
    check("an unknown command is reported, not ignored", r.err.includes("unknown command"), true, r.out + r.err);

    // The byte budget, from the shell. The library's tests cover the rules;
    // this covers the flag reaching the store and the refusal reaching the
    // terminal, which are the two things a caller sees.
    r = run("memory", ["--max-bytes", "10", "put a 12345", "put b 12345", "put c 12345", "keys", "stats"], dir);
    check("a byte budget evicts to stay inside it", r.out.includes("b, c"), true, r.out + r.err);
    check("and the budget is reported", r.out.includes("bytes     10 of 10"), true, r.out + r.err);

    r = run("memory", ["--max-bytes", "10", "put big 12345678901"], dir);
    check("a value too large for the budget is refused", r.err.includes("could not store big"), true, r.out + r.err);

    r = run("memory", ["put a hello", "stats"], dir);
    check("a store with no budget says so", r.out.includes("bytes     5 (no limit)"), true, r.out + r.err);

    // A flag that cannot be honoured is reported, not quietly replaced.
    r = run("memory", ["--capacity", "0", "put a 1"], dir);
    check("a capacity of zero is refused", r.err.includes("capacity must be a positive"), true, r.out + r.err);

    r = run("memory", ["--max-bytes", "-1", "put a 1"], dir);
    check("a negative byte budget is refused", r.err.includes("budget cannot be negative"), true, r.out + r.err);

    // ---- cmd/memory: the scopes ----
    // A scope is a partition of the keyspace and the limits are the store's.
    // The check that matters is the last one: a write into one scope took an
    // entry out of another, which is what "the budget is the store's" means.
    // The output is compared line by line, because a `put` echoes the key it
    // stored and "k1" in the echo is not "k1" in the key list.
    const lines = (s) => (s || "").trim().split(/\r?\n/);
    const lastLine = (s) => lines(s).pop();

    r = run("memory", ["put k1 the cat sat", "scope work", "put k2 the cat sat on the mat", "keys"], dir);
    check("a scope holds its own keys", lines(r.out).includes("k2"), true, r.out + r.err);
    check("another scope's keys are not here", lines(r.out).includes("k1"), false, r.out + r.err);

    r = run("memory", ["put k1 the cat sat", "scope work", "put k2 the cat sat on the mat", "scopes"], dir);
    check("the scopes are listed", lastLine(r.out), "default, work");

    r = run("memory", ["--scope", "work", "put k1 the cat sat", "scopes"], dir);
    check("--scope picks the scope to work in", lastLine(r.out), "work");

    r = run("memory", ["put k1 the cat sat", "scope work", "put k2 the cat sat on the mat", "search-all cat"], dir);
    check("a search across the store says which scope a hit is in", r.out.includes("default  k1"), true, r.out + r.err);
    check("...and the other scope's hit too", r.out.includes("work  k2"), true, r.out + r.err);

    // The capacity is the store's: the third entry does not fit, and the room
    // is made by taking an entry out of the *other* scope.
    r = run("memory", ["--capacity", "2", "put k1 aaa", "scope work", "put k2 bbb", "scope notes", "put k3 ccc", "scopes", "stats"], dir);
    check("a write in one scope can evict an entry in another", lines(r.out).includes("notes, work"), true, r.out + r.err);
    check("...and the eviction is counted", r.out.includes("evictions 1"), true, r.out + r.err);

    // Clearing one scope leaves the others alone; clearing the store does not.
    r = run("memory", ["put k1 aaa", "scope work", "put k2 bbb", "clear", "scopes"], dir);
    check("clear forgets this scope only", lastLine(r.out), "default");
    r = run("memory", ["put k1 aaa", "scope work", "put k2 bbb", "clear-all", "scopes"], dir);
    check("clear-all forgets every scope", lastLine(r.out), "(no scopes hold anything)");

    // ---- cmd/memory: how much an entry counts ----
    // The importance is a weight in the search score, so the check is about
    // the *ranking*: the demoted entry is found less strongly.
    r = run("memory", ["put a the cat sat", "put b the cat sat --importance 0.25", "search cat"], dir);
    check("a less important entry is found less strongly", r.out.includes("a  0.333"), true, r.out + r.err);
    check("...and the demoted one keeps its own score", r.out.includes("b  0.083"), true, r.out + r.err);
    r = run("memory", ["put a x --importance 0.5", "entries"], dir);
    check("the importance is reported with the entry", r.out.includes("importance 0.5"), true, r.out + r.err);

    // A flag the store cannot honour is reported, not quietly replaced.
    r = run("memory", ["put a x --importance 0"], dir);
    check("an importance of zero is refused", r.err.includes("importance must be more than zero"), true, r.out + r.err);
    r = run("memory", ["put a x --importance 2"], dir);
    check("an importance above one is refused", r.err.includes("at most one"), true, r.out + r.err);
    r = run("memory", ["put a x --importance zzz"], dir);
    check("an importance that is not a number is refused", r.err.includes("not a number"), true, r.out + r.err);
    r = run("memory", ["put a x --ttl 0"], dir);
    check("a lifetime of nothing is refused", r.err.includes("lifetime must be at least one millisecond"), true, r.out + r.err);

    // ---- cmd/memory: the labels on an entry ----
    // The labels say what an entry is, and a filter says which of them a
    // search may look at. The check is about *which entries come back*, not
    // about how they are ranked.
    //
    // A `put` echoes the value it stored, so "the cat ran" is in the output
    // whether or not the search found it. The score is what says a line is a
    // hit, so the hits are the lines that carry one.
    const hits = (s) => lines(s).filter((l) => /^\S+\s+\d+\.\d{3}\s/.test(l));
    const hitText = (s) => hits(s).join("\n");

    r = run("memory", ["put note the cat sat --meta kind=note", "put task the cat ran --meta kind=task", "search cat"], dir);
    check("an entry is labelled with what it was given", r.out.includes("kind=note"), true, r.out + r.err);
    check("...and the search shows the labels of a hit", hitText(r.out).includes("kind=note"), true, r.out + r.err);
    check("...and both entries are found without a filter", hits(r.out).length, 2, r.out + r.err);
    r = run("memory", ["put note the cat sat --meta kind=note", "put task the cat ran --meta kind=task", "search cat --where kind=note"], dir);
    check("a filter leaves out the entries it turns away", hitText(r.out).includes("the cat ran"), false, r.out + r.err);
    check("...and keeps the ones it admits", hitText(r.out).includes("the cat sat"), true, r.out + r.err);
    r = run("memory", ["put note the cat sat --meta kind=note --meta tag=urgent", "put task the cat ran --meta kind=task", "search cat --where kind=note --where tag=urgent"], dir);
    check("several filters are combined with and", hitText(r.out).includes("the cat sat") && !hitText(r.out).includes("the cat ran"), true, r.out + r.err);
    r = run("memory", ["put note the cat sat --meta kind=note", "put task the cat ran --meta kind=task", "search cat --without kind=task"], dir);
    check("--without k=v turns away the label with that value", hitText(r.out).includes("the cat sat") && !hitText(r.out).includes("the cat ran"), true, r.out + r.err);
    r = run("memory", ["put note the cat sat --meta kind=note --meta tag=urgent", "put task the cat ran --meta kind=task", "search cat --where tag"], dir);
    check("--where k asks for the label with any value", hitText(r.out).includes("the cat sat") && !hitText(r.out).includes("the cat ran"), true, r.out + r.err);
    r = run("memory", ["put note the cat sat --meta kind=note", "put task the dog ran --meta kind=task", "entries --where kind=note"], dir);
    check("the entries can be listed by their labels alone", r.out.includes("note (age") && !r.out.includes("task (age"), true, r.out + r.err);

    // A label the store cannot hold is reported, not quietly dropped.
    r = run("memory", ["put a x --meta =value"], dir);
    check("a label with no name is refused", r.err.includes("label needs a name"), true, r.out + r.err);
    r = run("memory", ["put a x --meta noequals"], dir);
    check("a label that is not key=value is refused", r.err.includes("must be key=value"), true, r.out + r.err);

    // ---- cmd/memory: the pin ----
    // A pin says an entry is never thrown away to make room for another one.
    // It is absolute: a store that cannot make room refuses the write rather
    // than breaking the pin.
    r = run("memory", ["put a x --pinned", "entries"], dir);
    check("a pinned entry is reported with the entry", r.out.includes(", pinned"), true, r.out + r.err);
    r = run("memory", ["put a x", "entries"], dir);
    check("...and an entry that is not pinned says nothing about it", !r.out.includes(", pinned"), true, r.out + r.err);

    r = run("memory", ["--capacity", "2", "put keep kept --pinned", "put other dropped", "put new new", "keys"], dir);
    check("a pinned entry is not the one thrown away", lastLine(r.out), "keep, new");
    r = run("memory", ["--capacity", "2", "put keep kept", "put other dropped", "put new new", "keys"], dir);
    check("...and without the pin it is", lastLine(r.out), "new, other");

    r = run("memory", ["--capacity", "1", "put a kept --pinned", "put b no room", "keys"], dir);
    check("a store of pinned entries refuses the write", r.err.includes("could not store b"), true, r.out + r.err);
    check("...and the entry it would have thrown away is still there", lastLine(r.out), "a");

    r = run("memory", ["put a x", "pin a", "entries"], dir);
    check("pin changes the pin of an entry that is there", r.out.includes(", pinned"), true, r.out + r.err);
    r = run("memory", ["put a x --pinned", "unpin a", "entries"], dir);
    check("unpin takes it away again", !r.out.includes(", pinned"), true, r.out + r.err);
    r = run("memory", ["pin nothing"], dir);
    check("pinning a key that is not there says so", r.out.includes("nothing to pin"), true, r.out + r.err);

    r = run("memory", ["--manual-clock", "put a x --pinned --ttl 1000", "advance 1000", "get a"], dir);
    check("a pinned entry still expires when its time is up", r.out.includes("a -> (nothing)"), true, r.out + r.err);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }

  log("");
  log(failures === 0 ? "all cli smoke checks passed" : `${failures} cli smoke check(s) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

try {
  main();
} catch (e) {
  console.error("cli smoke test failed to run:", e.message);
  process.exit(2);
}
