// The dynamic security probe.
//
//   node qa/dast.mjs
//
// Every binary is driven as a real process with **hostile** arguments: the
// malformed, the oversized, the path-traversing and the simply wrong. A
// program that refuses bad input is working; a program that *falls over* on
// bad input is a defect, and the difference between those two is the whole
// point of this file.
//
// Three things are checked, and they are the three ways a program can fail
// while handling input it did not expect:
//
//   1. it **crashes** — an abnormal exit, not a refusal;
//   2. it **hangs** — it never returns, so the run has to be cut off;
//   3. it **leaks a panic** — the runtime's own words in stderr, which is
//      what a crash looks like when the exit code has been tidied away.

import { build, run, scratch, cleanup, classify, log } from "./lib.mjs";

/** The runtime's own words for "something went wrong that I did not plan for". */
const PANIC_MARKERS = [
  "panic",
  "RUST_BACKTRACE",
  "unhandled exception",
  "Aborted",
  "assertion failed",
  "index out of bounds",
  "stack overflow",
  "Segmentation fault",
  "core dumped",
];

const BINARIES = ["cmd/main", "cmd/persist", "cmd/memory", "cmd/memory_db", "cmd/sa"];

function hostileStrings() {
  const long = "x".repeat(20000);
  return {
    empty: "",
    space: "   ",
    quote: "'",
    dquote: '"',
    unterminated: "SELECT 'unterminated",
    semicolon: "SELECT 1; DROP TABLE tesseract;",
    nul: "a" + String.fromCharCode(0) + "b",
    control: "a" + String.fromCharCode(7) + "b",
    unicode: "苹果 手机 🍎",
    deepParens: "SELECT " + "(".repeat(400) + "1" + ")".repeat(400),
    longIdent: "SELECT " + "a".repeat(5000) + " FROM tesseract",
    longValue: "INSERT INTO tesseract (key,value) VALUES ('k','" + "v".repeat(50000) + "') AT 1;",
    bigInList:
      "SELECT * FROM tesseract WHERE key IN (" +
      Array.from({ length: 5000 }, (_, i) => `'k${i}'`).join(",") +
      ")",
    nested: "SELECT json_extract('{\"a\":{\"b\":{\"c\":1}}}', '$.a.b.c');",
    injection: "'; DROP TABLE tesseract; --",
    traversal: "../../../../etc/passwd",
    windowsTraversal: "..\\..\\..\\Windows\\System32\\drivers\\etc\\hosts",
    long,
  };
}

/** The cases, per binary. Each is an argv array. */
function cases(dir, s) {
  const db = "test.db";
  const out = [];

  // ---- cmd/main: the SQL surface and the dot commands ----
  for (const [name, value] of Object.entries(s)) {
    out.push(["cmd/main", [value], `main: a ${name} argument`]);
    out.push(["cmd/main", [value, value], `main: two ${name} arguments`]);
  }
  out.push(["cmd/main", ["--side", "0", ".status"], "main: --side 0"]);
  out.push(["cmd/main", ["--side", "-1", ".status"], "main: --side -1"]);
  out.push(["cmd/main", ["--side", "216", ".status"], "main: --side 216"]);
  out.push(["cmd/main", ["--side", "99999999999999999999", ".status"], "main: --side beyond Int32"]);
  out.push(["cmd/main", ["--side", "abc", ".status"], "main: --side not a number"]);
  out.push(["cmd/main", [".open", s.traversal], "main: .open traversal"]);
  out.push(["cmd/main", [".open", s.windowsTraversal], "main: .open windows traversal"]);
  out.push(["cmd/main", [".open", ""], "main: .open empty"]);
  out.push(["cmd/main", [".export", s.traversal], "main: .export traversal"]);
  out.push(["cmd/main", [".export", "tsr", s.traversal], "main: .export with a traversal name"]);
  out.push(["cmd/main", [".import", "no-such-file.tsr"], "main: .import of a missing file"]);
  out.push(["cmd/main", [".import", dir], "main: .import of a directory"]);
  out.push(["cmd/main", [".help", s.long], "main: .help with a huge argument"]);
  out.push(["cmd/main", [".nosuchcommand"], "main: an unknown dot command"]);
  out.push(["cmd/main", [".solve", ".verify"], "main: solve then verify"]);

  // ---- cmd/persist: the same SQL, but against a file ----
  out.push(["cmd/persist", ["--db", db, s.injection], "persist: an injection in a statement"]);
  out.push(["cmd/persist", ["--db", s.traversal, ".status"], "persist: a traversal as the database path"]);
  out.push(["cmd/persist", ["--db", "", ".status"], "persist: an empty database path"]);
  out.push(["cmd/persist", ["--db", db, s.bigInList], "persist: a 5000-item IN list"]);
  out.push(["cmd/persist", ["--db", db, s.deepParens], "persist: 400 nested parens"]);

  // ---- cmd/memory: the command layer ----
  for (const [name, value] of Object.entries(s)) {
    out.push(["cmd/memory", [value], `memory: a ${name} command`]);
    out.push(["cmd/memory", ["put", "k", value], `memory: a ${name} value`]);
  }
  out.push(["cmd/memory", ["--capacity", "0", "keys"], "memory: --capacity 0"]);
  out.push(["cmd/memory", ["--capacity", "-5", "keys"], "memory: --capacity -5"]);
  out.push(["cmd/memory", ["--max-bytes", "-1", "keys"], "memory: --max-bytes -1"]);
  out.push(["cmd/memory", ["--ttl", "-1", "put", "k", "v"], "memory: a negative ttl"]);
  out.push(["cmd/memory", ["--ttl", "99999999999999999999", "put", "k", "v"], "memory: a ttl beyond Int32"]);
  out.push(["cmd/memory", ["--evict", "bogus", "keys"], "memory: an unknown eviction policy"]);
  out.push(["cmd/memory", ["--by", "bogus", "keys"], "memory: an unknown similarity"]);
  out.push(["cmd/memory", ["--half-life", "0", "keys"], "memory: --half-life 0"]);
  out.push(["cmd/memory", ["put"], "memory: put with no key"]);
  out.push(["cmd/memory", ["get"], "memory: get with no key"]);
  out.push(["cmd/memory", ["search"], "memory: search with no query"]);
  out.push(["cmd/memory", ["advance", "notanumber"], "memory: advance with a non-number"]);
  out.push(["cmd/memory", ["advance", "-5"], "memory: advance backwards"]);

  // ---- cmd/memory_db: the durable store and the index ----
  out.push(["cmd/memory_db", ["--file", "", "keys"], "memory_db: an empty checkpoint path"]);
  out.push(["cmd/memory_db", ["--file", s.traversal, "keys"], "memory_db: a traversal as the checkpoint path"]);
  out.push(["cmd/memory_db", ["--file", dir, "keys"], "memory_db: a directory as the checkpoint path"]);
  out.push(["cmd/memory_db", ["--file", db, "put", "k", "v"], "memory_db: a normal write"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", dir, "index"], "memory_db: a directory as the index path"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", "", "index"], "memory_db: an empty index path"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", db, "index"], "memory_db: the index is the checkpoint"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", "idx", "index-find", s.quote], "memory_db: a quoted word in the lookup"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", "idx", "index-find", s.long], "memory_db: a huge word in the lookup"]);
  out.push(["cmd/memory_db", ["--file", db, "--index", "idx", "index"], "memory_db: a normal index build"]);
  out.push(["cmd/memory_db", ["--file", db, "put", "k", s.longValue], "memory_db: a huge value"]);

  // ---- cmd/sa: the scan database ----
  out.push(["cmd/sa", ["--db", s.traversal, "list"], "sa: a traversal as the database path"]);
  out.push(["cmd/sa", ["--db", db, "nosuchcommand"], "sa: an unknown command"]);
  out.push(["cmd/sa", ["--db", db, "parse", s.injection], "sa: an injection in the parse command"]);

  return out;
}

function main() {
  log("building the binaries...");
  for (const b of BINARIES) build(b);

  const dir = scratch("dast");
  const strings = hostileStrings();
  const all = cases(dir, strings);
  log(`running ${all.length} hostile cases against ${BINARIES.length} binaries...`);
  log("");

  let failures = 0;
  let undeliverable = 0;
  const byKind = new Map();
  for (const [pkg, args, name] of all) {
    const r = run(pkg, args, dir, 15000);
    const verdict = classify(r);
    if (verdict && verdict.kind === "undeliverable") {
      undeliverable++;
      continue;
    }
    const lower = (r.out + r.err).toLowerCase();
    const panic = PANIC_MARKERS.find((p) => lower.includes(p.toLowerCase()));
    let problem = null;
    if (verdict) problem = `${verdict.kind}: ${verdict.detail}`;
    else if (panic) problem = `panic marker: ${panic}`;
    if (problem) {
      failures++;
      const kind = problem.split(":")[0];
      byKind.set(kind, (byKind.get(kind) || 0) + 1);
      log(`FAIL  ${name}`);
      log(`      ${problem}`);
      log(`      args: ${JSON.stringify(args).slice(0, 200)}`);
      log(`      out:  ${r.out.slice(0, 200).replace(/\n/g, "\\n")}`);
      log(`      err:  ${r.err.slice(0, 300).replace(/\n/g, "\\n")}`);
    }
  }
  cleanup(dir);

  log("");
  if (failures === 0) {
    log(`all ${all.length - undeliverable} deliverable hostile cases refused cleanly`);
    if (undeliverable > 0) {
      log(`  ${undeliverable} case(s) were not deliverable at all: the command line exceeded what the OS can carry, so the program never started`);
    }
  } else {
    log(`${failures} of ${all.length} hostile cases fell over`);
    for (const [kind, n] of byKind) log(`  ${kind}: ${n}`);
  }
  process.exit(failures === 0 ? 0 : 1);
}

main();
