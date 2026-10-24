// How the CLIs scale, and where they stop scaling.
//
//   node qa/perf.mjs
//
// Two questions, and they are different:
//
//   1. **Does it keep up?** A statement of a given size should take a time
//      that grows with the size, not faster than it.
//   2. **Does it stop?** A program that takes minutes on an input a person
//      can type is a program that can be made to look busy, and a caller
//      cannot tell that from a program that is working.
//
// The scaling exponent is measured rather than assumed: the time is fitted
// against the size, and an exponent near 1 is linear, 2 is quadratic, 3 is
// cubic. A parser that is quadratic is a denial of service wearing a
// parser's clothes.
//
// The first four sections answer that for one statement at a time. The five
// that follow answer it for the rest of the system under load: the SQL index
// over a full store, the executor over many rows, the checkpoint file as it
// grows, a long run's throughput, and the lattice everything lives in.
//
// Every number below comes from a binary that was actually run. Where a
// measurement is not possible the section says so, rather than leaving the
// gap looking like an oversight.

import { build, run, scratch, cleanup, log, classify } from "./lib.mjs";
import fs from "node:fs";
import path from "node:path";

/** The time a statement takes, in milliseconds. */
function timeStatement(dir, sql, repeats = 1) {
  const started = Date.now();
  for (let i = 0; i < repeats; i++) run("cmd/main", [sql], dir, 120000);
  return (Date.now() - started) / repeats;
}

/** The least-squares slope of log(time) against log(size). */
function exponent(sizes, times) {
  const n = sizes.length;
  const lx = sizes.map(Math.log);
  const ly = times.map((t) => Math.log(Math.max(t, 0.001)));
  const mx = lx.reduce((a, b) => a + b, 0) / n;
  const my = ly.reduce((a, b) => a + b, 0) / n;
  let num = 0;
  let den = 0;
  for (let i = 0; i < n; i++) {
    num += (lx[i] - mx) * (ly[i] - my);
    den += (lx[i] - mx) ** 2;
  }
  return den === 0 ? 0 : num / den;
}

// ---------------------------------------------------------------------------
// The helpers the load sections share.
// ---------------------------------------------------------------------------

/**
 * How many times a measurement is repeated.
 *
 * A single sample of a 3 ms operation is noise, and this harness drives real
 * processes on a shared machine, so every measurement here is taken over
 * several rounds and the middle of them is the answer. The slowest sample of
 * a process that starts up in 35 ms says more about the machine than about
 * the program, and the fastest one says more about the program than about
 * the machine only by luck.
 */
const REPEATS = 9;

/** The same, for the runs that are long enough that repeating them is dear. */
const HEAVY_REPEATS = 3;

/**
 * The same, for the reload: it is a couple of milliseconds against a
 * process launch, so it needs the rounds more than the others do.
 */
const RELOAD_REPEATS = 9;

/**
 * The same, for the index: the totals it compares are whole processes that
 * end in a durable write, and the time that write takes moves with the
 * machine's disk.
 */
const INDEX_REPEATS = 15;

/** The middle of a list of samples; the mean of the middle two when even. */
function median(samples) {
  const s = [...samples].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

/**
 * Times probes against each other, in pairs.
 *
 * The probes are run round-robin and each one is compared with the first in
 * the same round, so the noise a machine adds to a whole stretch of time -
 * the scheduler, the host doing something else, the page cache - lands on
 * both members of a pair and mostly cancels. The difference of two
 * independently timed runs does not cancel: it is the difference of two
 * noises, and what it reports is a fact about the machine.
 *
 * `probes` is a list of functions returning milliseconds. The result is the
 * middle of the paired differences, probe 0 against each of the others.
 *
 * The middle is the unbiased statistic, and it is the right one when the
 * noise is symmetric. Where the noise is one-sided - a durable write, whose
 * time only ever grows when the machine is busy - the fastest round is the
 * one that measured the work rather than the disk, and the caller says so.
 */
function measurePairs(probes, repeats = REPEATS) {
  const diffs = probes.map(() => []);
  for (let r = 0; r < repeats; r++) {
    const times = probes.map((p) => p());
    for (let p = 1; p < probes.length; p++) diffs[p].push(times[p] - times[0]);
  }
  return diffs.map((d) => median(d));
}

/**
 * Times probes that do not measure the same thing.
 *
 * There is nothing to pair here, so the middle of each probe's runs is the
 * estimate: the fastest run is the one that was disturbed least, which is
 * right for a cost that does not vary, and the middle is right when the
 * spread is symmetric.
 */
function measureEach(probes, repeats = REPEATS, stat = "median") {
  const all = probes.map(() => []);
  for (let r = 0; r < repeats; r++) {
    for (let p = 0; p < probes.length; p++) all[p].push(probes[p]());
  }
  return all.map((d) => (stat === "min" ? Math.min(...d) : median(d)));
}

/**
 * What a run means, as one line.
 *
 * `classify` keeps the three answers apart - the operating system refused the
 * request, the program hung, the program crashed - because collapsing them
 * is how a QA harness reports a defect that is not there.
 */
function status(r) {
  const c = classify(r);
  if (c) return c.kind + " - " + c.detail;
  return r.code === 0 ? "ok" : "exit " + r.code;
}

/**
 * Fits log(time) against log(size) and says what the fit means.
 *
 * A fit over a signal that sits inside the measurement noise is not a scaling
 * law, so the spread between the fastest and the slowest sample is checked
 * too: a spread under 1.5 means the time did not really change with the size,
 * and that is reported as a flat cost rather than dressed up as an exponent.
 */
function scaling(sizes, times) {
  const e = exponent(sizes, times);
  const lo = Math.min(...times);
  const hi = Math.max(...times);
  const spread = hi / Math.max(lo, 0.001);
  const flat = spread < 1.5;
  const floored = times.filter((t) => t <= 0).length;
  return {
    e,
    flat,
    floored,
    text: flat
      ? "flat - the samples do not separate (spread " + spread.toFixed(2) + "), so this is a constant cost, not a scaling law"
      : floored > 0
      ? "at or below the measurement floor at " + floored + " of " + times.length + " sizes, so the exponent is a floor and not a law: " + verdict(e)
      : e < 0.7
      ? "sub-linear - a fixed cost dominates, so the cost grows more slowly than the size: " + verdict(e)
      : verdict(e),
  };
}

/**
 * The timestamps of the log lines a run printed.
 *
 * The CLI mirrors its log to stderr, one line per statement, each stamped
 * with the host clock in milliseconds. That log is the only per-statement
 * clock the program keeps, so a run's own log is what a windowed throughput
 * has to be read from - measuring it from outside would only see the whole
 * process.
 */
function logStamps(err) {
  const out = [];
  for (const line of (err || "").split(/\r?\n/)) {
    const m = /^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3})Z\]/.exec(line);
    if (m) out.push(Date.parse(m[1]));
  }
  return out;
}

/**
 * The per-window cost of a run, read from its own log.
 *
 * A window of `size` statements is timed from the first stamp in it to the
 * last, which covers `size - 1` gaps between statements, so that is what the
 * total is divided by.
 */
function windows(stamps, size) {
  const out = [];
  for (let start = 0; start + size <= stamps.length; start += size) {
    const slice = stamps.slice(start, start + size);
    const ms = slice[slice.length - 1] - slice[0];
    out.push({ ms, each: ms / (size - 1), from: start + 1, to: start + size });
  }
  return out;
}

/** The words an entry holds, so that an index over it has rows to hold. */
function wordsOf(i, count) {
  const w = [];
  for (let j = 0; j < count; j++) w.push("w" + i + "x" + j);
  return w.join(" ");
}

/**
 * Puts `n` entries into the durable store at `db`.
 *
 * The puts go in several processes when there are many of them: the store
 * persists in its file, and a command line longer than the platform carries
 * is a limit of the platform, not of the store. Each process opens the store
 * the earlier ones left behind, so the result is the same store.
 */
function buildStore(dir, db, n, words, chunk = 60) {
  const started = Date.now();
  for (let start = 0; start < n; start += chunk) {
    const args = ["--file", db, "--capacity", "255"];
    for (let i = start; i < Math.min(start + chunk, n); i++) {
      args.push(`put k${i} ${wordsOf(i, words)}`);
    }
    const r = run("cmd/memory_db", args, dir, 300000);
    if (status(r) !== "ok") return r;
  }
  return { code: 0, out: "", err: "", signal: null, error: null, ms: Date.now() - started };
}

function main() {
  log("building cmd/main...");
  build("cmd/main");
  log("building cmd/memory_db...");
  build("cmd/memory_db");
  const dir = scratch("perf");
  log("");

  // ---- 1. a long value in one statement ----
  log("a single INSERT with a growing value");
  log("  bytes        ms        ms/KB");
  const sizes = [1000, 2000, 4000, 8000, 16000, 32000, 64000];
  const times = [];
  for (const size of sizes) {
    const sql = `INSERT INTO tesseract (key,value) VALUES ('k','${"v".repeat(size)}') AT 1;`;
    const ms = timeStatement(dir, sql);
    times.push(ms);
    log(`  ${String(size).padStart(6)}  ${ms.toFixed(0).padStart(9)}  ${(ms / (size / 1024)).toFixed(1).padStart(9)}`);
  }
  const e1 = exponent(sizes, times);
  log(`  exponent: ${e1.toFixed(2)}  ${verdict(e1)}`);
  // The largest value is longer than the platform's command line carries, so
  // the program never sees it. That row is the refusal and not an insert,
  // and the fit above includes it - so the refusal is named here rather than
  // left to look like a measurement.
  const biggest = `INSERT INTO tesseract (key,value) VALUES ('k','${"v".repeat(sizes[sizes.length - 1])}') AT 1;`;
  const refused = run("cmd/main", [biggest], dir, 120000);
  const c = classify(refused);
  if (c) {
    log(`  note: the ${sizes[sizes.length - 1]} byte value was ${c.kind} - the command line is longer than`);
    log("  the platform carries, so that row above is the refusal and not an insert.");
  }
  log("");

  // ---- 2. a growing IN list ----
  log("a SELECT with a growing IN list");
  log("  items        ms        ms/item");
  const counts = [100, 200, 400, 800, 1600, 3200];
  const inTimes = [];
  for (const n of counts) {
    const list = Array.from({ length: n }, (_, i) => `'k${i}'`).join(",");
    const sql = `SELECT * FROM tesseract WHERE key IN (${list});`;
    const ms = timeStatement(dir, sql);
    inTimes.push(ms);
    log(`  ${String(n).padStart(6)}  ${ms.toFixed(0).padStart(9)}  ${(ms / n).toFixed(3).padStart(9)}`);
  }
  const e2 = exponent(counts, inTimes);
  log(`  exponent: ${e2.toFixed(2)}  ${verdict(e2)}`);
  log("");

  // ---- 3. many statements, one at a time ----
  log("many small statements, one process each");
  const perStmt = 40;
  const started = Date.now();
  for (let i = 0; i < perStmt; i++) {
    run("cmd/main", [`INSERT INTO tesseract (key,value) VALUES ('k${i}','v') AT 1;`], dir, 120000);
  }
  const each = (Date.now() - started) / perStmt;
  log(`  ${perStmt} statements in one process each: ${each.toFixed(0)} ms per statement`);
  log("");

  // ---- 4. the durable store at its capacity ----
  log("the durable memory at its checkpoint limit");
  const db = "load.db";
  const writes = 255;
  const w0 = Date.now();
  const args = ["--file", db];
  for (let i = 0; i < writes; i++) args.push(`put k${i} value ${i}`);
  const r = run("cmd/memory_db", args, dir, 300000);
  const wms = Date.now() - w0;
  log(`  ${writes} writes in one process: ${wms} ms  (${(wms / writes).toFixed(1)} ms per write)`);
  log(`  exit ${r.code}${r.err ? "  err: " + r.err.slice(0, 120) : ""}`);
  const r2 = run("cmd/memory_db", ["--file", db, "keys"], dir, 300000);
  log(`  reopening it: ${r2.ms} ms, ${(r2.out || "").trim().split(/\s*,\s*/).length} keys`);
  log("");

  // The five sections below each answer one question about the system under
  // load. A section that cannot answer its question says so and moves on.
  const sections = [
    sectionIndexOverAFullStore,
    sectionExecutorOverManyRows,
    sectionTheCheckpointAsItGrows,
    sectionASustainedRun,
    sectionTheLatticeSize,
  ];
  for (const section of sections) {
    try {
      section(dir);
    } catch (e) {
      log("  SECTION FAILED: " + (e && e.message ? e.message : String(e)));
      log("");
    }
  }

  cleanup(dir);
}

function verdict(e) {
  if (e < 1.3) return "(linear)";
  if (e < 1.7) return "(a bit worse than linear)";
  if (e < 2.3) return "(QUADRATIC - a denial of service wearing a parser's clothes)";
  return "(worse than quadratic)";
}

// ---------------------------------------------------------------------------
// 5. the SQL index over a full store
// ---------------------------------------------------------------------------

/**
 * The index over a store, at several sizes.
 *
 * The index is **derivative**: it holds nothing the entries do not, so it can
 * be thrown away and built again. Derivative is a claim about cost as well as
 * about content - a rebuild that costs more than the store it mirrors is
 * charging for something the store already holds. The bar is therefore
 * linear: the store's own size grows with the number of entries, so an index
 * over N entries has to be able to be rebuilt in O(N).
 *
 * Every measurement here is the **total** cost of a process that does the
 * work, and the baseline is the same process with no index work at all, so
 * the two can be compared. The totals are what is fitted, because a total is
 * a stable number and a difference of two totals is not: every command the
 * durable store runs ends in a durable write, and the time that write takes
 * moves with the machine's disk by more than the index's own work does.
 * So the exponent is fitted on the totals, and the marginal cost per entry -
 * a difference of the largest and the smallest, which are both large - is
 * reported beside it.
 */
function sectionIndexOverAFullStore(dir) {
  log("the SQL index over a full store");
  log("  the index is derivative: it holds nothing the entries do not, so a");
  log("  rebuild must not cost more than the store it was built from.");
  log("");

  const WORDS = 50; // words per entry, so the index has rows to hold
  const counts = [16, 32, 64, 128, 255];
  const rebuildTotals = [];
  const baseTotals = [];
  const findTotals = [];
  const indexBytes = [];
  const storeBytes = [];

  log("  the durable store holds at most 255 entries - the checkpoint lattice has");
  log("  one cell per entry and one for its header - so 255 is the largest store");
  log("  there is to index. Each entry holds 50 words, so the index over it holds");
  log("  50 rows per entry and the rebuild has rows to write.");
  log("");
  log("  entries    rows   rebuild ms   base ms   find ms   index bytes   store bytes");
  for (const n of counts) {
    const db = path.join(dir, `index-${n}.db`);
    const idx = path.join(dir, `index-${n}.idx`);
    for (const f of [db, idx]) if (fs.existsSync(f)) fs.unlinkSync(f);
    buildStore(dir, db, n, WORDS, 40);

    let rows = 0;
    const times = measureEach([
      // the baseline: the same store, opened, with no index work at all
      () => run("cmd/memory_db", ["--file", db, "--capacity", "255", "--index", idx, "keys"], dir, 60000).ms,
      // the rebuild: the index file is thrown away first, so this is a
      // rebuild from nothing - what a caller who does not trust the index does
      () => {
        if (fs.existsSync(idx)) fs.unlinkSync(idx);
        const r = run("cmd/memory_db", ["--file", db, "--capacity", "255", "--index", idx, "index"], dir, 60000);
        const m = /(\d+) rows, (\d+) entries/.exec(r.out || "");
        if (m) rows = Number(m[1]);
        return r.ms;
      },
      // the lookup. The CLI checks the index against the store before it
      // answers, so what is measured is that check plus the lookup - the check
      // is O(rows) and the lookup itself is the small part of it.
      () => run("cmd/memory_db", ["--file", db, "--capacity", "255", "--index", idx, "index-find", "w0x0"], dir, 60000).ms,
    ], INDEX_REPEATS);

    rebuildTotals.push(times[1]);
    baseTotals.push(times[0]);
    findTotals.push(times[2]);
    indexBytes.push(fs.existsSync(idx) ? fs.statSync(idx).size : 0);
    storeBytes.push(fs.existsSync(db) ? fs.statSync(db).size : 0);

    log(
      `  ${String(n).padStart(7)}  ${String(rows).padStart(5)}  ${times[1].toFixed(1).padStart(11)}  ${times[0].toFixed(1).padStart(8)}  ${times[2].toFixed(1).padStart(8)}  ${String(indexBytes[indexBytes.length - 1]).padStart(12)}  ${String(storeBytes[storeBytes.length - 1]).padStart(11)}`,
    );
  }
  log("");

  const last = counts.length - 1;
  const rb = scaling(counts, rebuildTotals);
  const fd = scaling(counts, findTotals);
  log(`  index rebuild, total:  ${rb.e.toFixed(2)}  ${rb.text}`);
  log(`  index lookup, total:  ${fd.e.toFixed(2)}  ${fd.text}`);
  // The index's own share: the rebuild's total minus the store's own cost,
  // taken at the ends of the range where both are large.
  const shareSmall = Math.max(rebuildTotals[0] - baseTotals[0], 0);
  const shareLarge = Math.max(rebuildTotals[last] - baseTotals[last], 0);
  const perEntry = (shareLarge - shareSmall) / (counts[last] - counts[0]);
  const storePerEntry = (baseTotals[last] - baseTotals[0]) / (counts[last] - counts[0]);
  log(
    `  the index's own share of the rebuild is ${shareSmall.toFixed(0)} ms over ${counts[0]} entries and`,
  );
  log(
    `  ${shareLarge.toFixed(0)} ms over ${counts[last]}, which is ${perEntry.toFixed(2)} ms per entry; the store's own`,
  );
  log(
    `  checkpoint write over the same range grows by ${storePerEntry.toFixed(2)} ms per entry.`,
  );
  log(
    `  A derivative index has to cost no more to rebuild than the data it`,
  );
  log(
    `  indexes: ${perEntry <= storePerEntry ? "this one does not." : "this one costs more than the store does."}`,
  );
  log("");
}

// ---------------------------------------------------------------------------
// 6. the executor over many rows
// ---------------------------------------------------------------------------

/**
 * The queries, over a lattice holding many rows.
 *
 * The rows and the query go into **one** process, so what is measured is the
 * executor and not a process starting up. The query is run several times in
 * that one process, because a single query over a few hundred rows costs
 * less than the noise of a process launch, and the extra runs give the
 * difference something to measure.
 *
 * The CLI does not stamp a SELECT in its log - only the statements that go
 * through the store's own writer are stamped - so the query cannot be timed
 * from the log the way the sustained run's inserts are. It is timed against
 * a second run that carries the same rows and no query, and the two are run
 * against each other so that the noise of the machine lands on both.
 *
 * The CLI renders and prints the answer, and that is inside the measurement:
 * a caller waits for the answer as it is written, not only for the rows that
 * were found.
 */
function sectionExecutorOverManyRows(dir) {
  log("the executor over many rows");
  log("  one process carries the rows and the query, and the query is run");
  log("  several times in that process so that the difference against a run");
  log("  with the same rows and no query is worth measuring.");
  log("");

  const SIDE = 5; // 625 cells; the rows have to fit in the lattice
  const counts = [64, 128, 256, 384];
  const REPEATS_QUERY = 9; // rounds of the paired measurement
  // The platform carries a command line of about 32,000 characters, and the
  // query is repeated in that one process to give the difference something to
  // measure - so the number of repetitions is whatever the room left by the
  // rows allows. A query over few rows is cheap, and it is repeated more
  // times to be measured at all.
  const COMMAND_LINE = 29000;
  const queries = [
    { label: "SELECT *", of: () => "SELECT * FROM tesseract;" },
    { label: "ORDER BY", of: () => "SELECT * FROM tesseract ORDER BY key;" },
    { label: "DISTINCT", of: () => "SELECT DISTINCT value FROM tesseract;" },
    {
      label: "LIMIT/OFF",
      of: (n) => `SELECT * FROM tesseract LIMIT 10 OFFSET ${Math.floor(n / 2)};`,
    },
    { label: "GROUP BY", of: () => "SELECT value, COUNT(*) FROM tesseract GROUP BY value;" },
  ];
  const times = queries.map(() => []);
  const failed = [];

  log("  rows   side  " + queries.map((q) => q.label.padStart(11)).join(""));
  for (const n of counts) {
    const inserts = [];
    for (let i = 1; i <= n; i++) {
      inserts.push(`INSERT INTO tesseract (key,value) VALUES ('k${i}','v${i % 10}') AT ${i};`);
    }
    const used = inserts.reduce((a, s) => a + s.length + 3, 0) + 120;
    const row = [];
    for (let q = 0; q < queries.length; q++) {
      const sql = queries[q].of(n);
      const times_run = Math.max(10, Math.min(100, Math.floor((COMMAND_LINE - used) / (sql.length + 3))));
      const withQuery = ["--side", String(SIDE), ...inserts];
      for (let j = 0; j < times_run; j++) withQuery.push(sql);
      let refused = "";
      const diffs = measurePairs(
        [
          () => run("cmd/main", ["--side", String(SIDE), ...inserts], dir, 300000).ms,
          () => {
            const r = run("cmd/main", withQuery, dir, 300000);
            if (!refused && status(r) !== "ok") refused = status(r);
            if (!refused && (r.out || "").includes("✗")) refused = "the query was refused";
            return r.ms;
          },
        ],
        REPEATS_QUERY,
      );
      if (refused) failed.push(`${queries[q].label} at ${n} rows: ${refused}`);
      const each = Math.max(diffs[1], 0) / times_run;
      times[q].push(each);
      row.push(each.toFixed(2).padStart(11));
    }
    log(`  ${String(n).padStart(4)}   ${String(SIDE).padStart(4)}  ${row.join("")}`);
  }
  log("");
  log(`  every row of the table is printed by the CLI, so the cost includes the`);
  log(`  answer as it is written - and the harness has to read it back, which is`);
  log(`  inside the measurement too. Side ${SIDE} is ${SIDE ** 4} cells, and the`);
  log(`  LIMIT/OFF row moves its offset with the row count.`);
  log("");
  for (let q = 0; q < queries.length; q++) {
    const s = scaling(counts, times[q]);
    log(`  ${queries[q].label.padEnd(9)}  ${s.e.toFixed(2)}  ${s.text}`);
  }
  if (failed.length) {
    log("");
    for (const f of failed) log("  not measured: " + f);
  }
  log("");

  // The operating system refuses a command line it cannot carry, and that is
  // not the program failing - it is the platform saying no. The lattice at
  // side 5 holds 625 rows, and this is what happens when one process is asked
  // to carry all of them.
  const tooMany = [];
  for (let i = 1; i <= 625; i++) {
    tooMany.push(`INSERT INTO tesseract (key,value) VALUES ('k${i}','v${i % 10}') AT ${i};`);
  }
  const refused = run("cmd/main", ["--side", String(SIDE), ...tooMany], dir, 120000);
  log(`  a side ${SIDE} lattice filled in one process (${tooMany.length} statements): ${status(refused)}`);
  if (refused.error) {
    log("  the command line is longer than the platform carries, so the rows of a");
    log("  full side 5 lattice cannot be loaded in one process here; the numbers");
    log("  above stop at the largest load the platform accepts.");
  }
  log("");
}

// ---------------------------------------------------------------------------
// 7. the checkpoint as it grows
// ---------------------------------------------------------------------------

/**
 * The checkpoint file, as the store behind it grows.
 *
 * Three numbers, and they answer three different questions:
 *
 * - **write** - what one checkpoint of an N-entry store costs. The store
 *   writes its checkpoint after every command, so a run of K commands writes
 *   it K times, and the difference between a run of K and a run of 1 is the
 *   cost of the extra writes.
 * - **reload** - what it costs to read the file back. The store refuses a
 *   checkpoint that holds more entries than its capacity, and it refuses it
 *   **after** the file has been read: the load is paid, the write is not. So a
 *   capacity of 1 against an N-entry file times the load and nothing else,
 *   and a capacity of 0 - refused before the store is even opened - is the
 *   process startup on its own.
 * - **size** - what the file takes, and how much of that is each entry.
 */
function sectionTheCheckpointAsItGrows(dir) {
  log("the checkpoint as it grows");
  log("  every entry here holds 100 words, so the file has something in it to");
  log("  read back; the entries are the same size throughout, so the size and");
  log("  the load grow with the number of entries and nothing else.");
  log("");

  const WORDS = 100; // words per entry, so the file is big enough to time
  const counts = [1, 10, 50, 100, 200, 255];
  const K = 20; // commands per run, so the extra writes have a span to measure
  const writeTimes = [];
  const reloadTimes = [];
  const sizes = [];

  log("  entries   build ms   write ms   reload ms     bytes   bytes/entry");
  for (const n of counts) {
    const db = path.join(dir, `checkpoint-${n}.db`);
    if (fs.existsSync(db)) fs.unlinkSync(db);
    const built = buildStore(dir, db, n, WORDS, 25);

    // One checkpoint write, timed as the difference between a run of K
    // commands and a run of one: both pay the startup, and the difference is
    // the extra writes.
    const [one, many] = measureEach([
      () => run("cmd/memory_db", ["--file", db, "--capacity", "255", "stats"], dir, 60000).ms,
      () => {
        const a = ["--file", db, "--capacity", "255"];
        for (let j = 0; j < K; j++) a.push("stats");
        return run("cmd/memory_db", a, dir, 60000).ms;
      },
    ]);
    const writeMs = Math.max(many - one, 0) / (K - 1);

    // The reload. A store of one entry cannot be refused after the load - the
    // capacity that would refuse it is refused before the store is opened -
    // so that row has no reload to report.
    let reloadMs = null;
    if (n > 1) {
      const times = measureEach([
        () => run("cmd/memory_db", ["--file", path.join(dir, "startup.db"), "--capacity", "0", "keys"], dir, 60000).ms,
        () => run("cmd/memory_db", ["--file", db, "--capacity", "1", "keys"], dir, 60000).ms,
      ], RELOAD_REPEATS);
      reloadMs = Math.max(times[1] - times[0], 0);
    }

    const bytes = fs.existsSync(db) ? fs.statSync(db).size : 0;
    writeTimes.push(writeMs);
    reloadTimes.push(reloadMs === null ? NaN : reloadMs);
    sizes.push(bytes);

    log(
      `  ${String(n).padStart(7)}  ${String(built.ms).padStart(9)}  ${writeMs.toFixed(1).padStart(9)}  ` +
        (reloadMs === null ? "n/a".padStart(10) : reloadMs.toFixed(1).padStart(10)) +
        `  ${String(bytes).padStart(8)}  ${(bytes / n).toFixed(0).padStart(11)}`,
    );
  }
  log("");

  const wr = scaling(counts, writeTimes);
  const sz = scaling(counts, sizes);
  log(`  checkpoint write:  ${wr.e.toFixed(2)}  ${wr.text}`);
  const reloadable = counts.filter((_, i) => !Number.isNaN(reloadTimes[i]));
  const reloadValues = reloadTimes.filter((t) => !Number.isNaN(t));
  const floored = reloadValues.filter((t) => t <= 0).length;
  if (reloadable.length >= 2) {
    if (floored > 0) {
      log(`  checkpoint reload: below the measurement floor at ${floored} of ${reloadable.length} sizes - a load`);
      log("  of that size costs less than the difference between two process launches");
      log("  can resolve, so there is no scaling law to fit.");
    } else {
      const rl = scaling(reloadable, reloadValues);
      log(
        `  checkpoint reload: ${median(reloadValues).toFixed(1)} ms at the median (${Math.min(...reloadValues).toFixed(1)} .. ${Math.max(...reloadValues).toFixed(1)} over ${reloadable.length} sizes)`,
      );
      log(`  exponent ${rl.e.toFixed(2)}  ${rl.text}`);
      log(
        `  the file is ${(sizes[sizes.length - 1] / sizes[0]).toFixed(0)}x bigger at ${counts[counts.length - 1]} entries than at ${counts[0]}, and the`,
      );
      log(
        `  load is the same few milliseconds: reading it back is a few`,
      );
      log(
        `  milliseconds against a process launch of forty, so it sits at the floor`,
      );
      log(`  of what this harness can resolve and no exponent is fitted over it.`);
    }
    const lastReload = reloadTimes[reloadTimes.length - 1];
    const lastWrite = writeTimes[writeTimes.length - 1];
    log(
      `  at ${counts[counts.length - 1]} entries a reload costs ${lastReload.toFixed(1)} ms and a write ${lastWrite.toFixed(1)} ms`,
    );
    log(
      `  (${(lastReload / Math.max(lastWrite, 0.001)).toFixed(2)}x) - a checkpoint that cost more to read back than to write would be a store that cannot be reopened cheaply.`,
    );
  }
  log(`  checkpoint size:   ${sz.e.toFixed(2)}  ${sz.text}`);
  log(
    `  the file holds a fixed page for every cell of the checkpoint lattice, so`,
  );
  log(
    `  the bytes per entry fall as the store fills; the exponent below 1 is`,
  );
  log(
    `  that fixed base, not a store that gets cheaper to keep. The checkpoint`,
  );
  log(
    `  does not grow superlinearly: ${sz.e < 1.3 ? "the file is sub-linear in the entries." : "the file grows faster than the entries do."}`,
  );
  log("");
}

// ---------------------------------------------------------------------------
// 8. a sustained run
// ---------------------------------------------------------------------------

/**
 * A long run, and whether it slows down.
 *
 * A store that gets slower as it fills is a different defect from one that is
 * slow to begin with, and the difference is only visible over a run: the
 * first window and the last one have to be compared.
 *
 * The SQL statements are timed from the run's **own log** - the CLI stamps
 * every statement it executes - so all of them are measured inside one
 * process, with no process startup in the middle of the measurement.
 *
 * The durable store prints no timestamps, so its windows are measured by
 * differencing the cumulative time of runs of different lengths: the cost of
 * the last block of puts is what the difference between the run that ends
 * there and the run that ended before it says.
 */
function sectionASustainedRun(dir) {
  log("a sustained run");
  log("");

  // ---- the SQL statements, in one process ----
  const SIDE = 5;
  const TOTAL = 400;
  const WINDOW = 100;
  const inserts = [];
  for (let i = 1; i <= TOTAL; i++) {
    inserts.push(`INSERT INTO tesseract (key,value) VALUES ('k${i}','v${i % 10}') AT ${i};`);
  }
  const run1 = run("cmd/main", ["--side", String(SIDE), ...inserts], dir, 300000);
  const stamps = logStamps(run1.err);
  log(`  ${TOTAL} INSERT statements in one process (side ${SIDE}): ${status(run1)}, ${run1.ms} ms`);
  if (stamps.length < TOTAL) {
    log(
      `  the log carries ${stamps.length} stamps for ${TOTAL} statements, so the windows below are`,
    );
    log("  measured over the statements the log does carry.");
  }
  const w = windows(stamps, WINDOW);
  if (w.length >= 2) {
    log(`  window      statements        ms    ms per statement`);
    for (const x of w) {
      log(
        `  ${String(x.from).padStart(5)}  ${String(x.from + "-" + x.to).padStart(12)}  ${String(x.ms).padStart(8)}  ${x.each.toFixed(3).padStart(16)}`,
      );
    }
    const first = w[0].each;
    const last = w[w.length - 1].each;
    const span = stamps[stamps.length - 1] - stamps[0];
    const ratio = last / Math.max(first, 0.001);
    // The log clock is a millisecond and the whole run spans a few of them,
    // so the window-to-window differences are at the clock's resolution and
    // the ratio is a statement about that resolution, not about drift.
    const resolved = span >= 10 * w.length;
    log(`  first window ${first.toFixed(3)} ms per statement, last window ${last.toFixed(3)} ms per statement`);
    log(
      `  ratio ${ratio.toFixed(2)}x  ` +
        (resolved
          ? driftVerdict(ratio)
          : "(not resolved - the log clock is a millisecond and the whole run spans " +
            span +
            " ms, so the window-to-window differences are at its resolution)"),
    );
    if (!resolved) {
      log("  the SQL store's statements are too cheap for this clock to resolve them");
      log("  apart, so this run says the statements are cheap and not that they");
      log("  do not drift; the durable store below is where the drift shows.");
    }
  } else {
    log("  too few windows to compare - the run did not carry enough stamps.");
  }
  log("");

  // ---- the durable store, in one process ----
  log("  the durable store, whose checkpoint is rewritten after every command:");
  const marks = [50, 100, 150, 200, 255];
  const cumulative = measureEach(
    marks.map((k) => () => {
      const file = path.join(dir, `sustained-${k}.db`);
      // The store is thrown away first: a run that opened a store left behind
      // by an earlier round would be measuring a bigger store than it says.
      if (fs.existsSync(file)) fs.unlinkSync(file);
      const args = ["--file", file, "--capacity", "255"];
      for (let i = 0; i < k; i++) args.push(`put k${i} ${wordsOf(i, 5)}`);
      const started = Date.now();
      run("cmd/memory_db", args, dir, 300000);
      return Date.now() - started;
    }),
    HEAVY_REPEATS,
    "min",
  );
  log("  puts in one process:");
  for (let i = 0; i < marks.length; i++) {
    log(`  ${String(marks[i]).padStart(4)} puts: ${String(cumulative[i]).padStart(6)} ms`);
  }
  log("  block      puts      ms    ms per put");
  let prev = 0;
  let prevN = 0;
  for (let i = 0; i < marks.length; i++) {
    const blockMs = cumulative[i] - prev;
    const blockN = marks[i] - prevN;
    log(
      `  ${String(prevN + 1 + "-" + marks[i]).padStart(5)}  ${String(blockN).padStart(7)}  ${String(blockMs).padStart(6)}  ${(blockMs / blockN).toFixed(2).padStart(12)}`,
    );
    prev = cumulative[i];
    prevN = marks[i];
  }
  const firstBlock = cumulative[0] / marks[0];
  const lastBlock =
    (cumulative[cumulative.length - 1] - cumulative[cumulative.length - 2]) /
    (marks[marks.length - 1] - marks[marks.length - 2]);
  log(`  first block ${firstBlock.toFixed(2)} ms per put, last block ${lastBlock.toFixed(2)} ms per put`);
  log(`  ratio ${(lastBlock / Math.max(firstBlock, 0.001)).toFixed(2)}x`);
  // The blocks are one sample each of a cost that is dominated by a durable
  // write, and that cost moves with the machine's disk. The whole run is the
  // robust number: an exponent of 1 means every put costs the same and 2
  // means the store costs twice as much to write as it did when it was empty.
  const cum = scaling(marks, cumulative);
  log(`  the run as a whole: ${cum.e.toFixed(2)}  ${cum.text}`);
  log(`  ${driftVerdictExponent(cum.e)}`);
  log("  (the blocks above are single samples of a cost the disk decides, so they");
  log("  move about; the exponent over the whole run is the one that holds.)");
  log("");
}

/** What an exponent over a whole run means for the store's drift. */
function driftVerdictExponent(e) {
  if (e > 1.3) return "(the store gets slower as it fills - a put costs more as the store grows)";
  if (e > 1.1) return "(the store gets a little slower as it fills - the cost of a put grows with the store)";
  if (e < 0.9) return "(the store gets faster as it fills)";
  return "(flat - the store does not get slower as it fills)";
}

/** What a ratio between the first and the last window means. */
function driftVerdict(ratio) {
  if (ratio > 1.25) return "(the run gets slower as the store fills)";
  if (ratio < 0.85) return "(the run gets faster as the store fills)";
  return "(flat - the store does not get slower as it fills)";
}

// ---------------------------------------------------------------------------
// 9. the lattice size
// ---------------------------------------------------------------------------

/**
 * What the lattice costs, and where it stops being usable.
 *
 * The lattice is `side^4` cells and every one of them is paid for when the
 * store is built, before a single statement runs. So the cost of the lattice
 * is what a process pays to open a store of that shape.
 *
 * The CLI answers with its help and returns when it is given no statements,
 * and it returns **before** it builds the lattice - so a run with no
 * statements is the process startup on its own, and the difference between
 * that and a run with one statement is what the lattice costs.
 *
 * A single insert is the same work whatever the lattice is shaped like, so
 * what grows with the side is the store's footprint, not the cost of a
 * statement.
 */
function sectionTheLatticeSize(dir) {
  log("the lattice size");
  log("  the lattice is side^4 cells and every cell is paid for when the store");
  log("  is built, so the run with no statements - which returns before the");
  log("  lattice is built - is what the process costs on its own.");
  log("");

  const sides = [3, 4, 5, 6, 8, 10, 16, 20, 25, 30, 40, 50, 60];
  const cells = [];
  const openTimes = [];
  const latticeTimes = [];

  log("  side    cells   no statements ms   open ms   lattice ms");
  for (const side of sides) {
    // Each round runs the two probes back to back, so the difference is
    // between neighbours in time and the machine's noise lands on both. The
    // lattice's cost is an allocation, which does not vary, and the noise
    // around it is all one-sided - a stretch of slow machine - so the
    // fastest round is the one that measured the cost and not the machine.
    const bareRuns = [];
    const openRuns = [];
    const diffRuns = [];
    for (let r = 0; r < 6; r++) {
      const bare = run("cmd/main", ["--side", String(side)], dir, 300000).ms;
      const open = run(
        "cmd/main",
        ["--side", String(side), "INSERT INTO tesseract (key,value) VALUES ('k1','v1') AT 1;"],
        dir,
        300000,
      ).ms;
      bareRuns.push(bare);
      openRuns.push(open);
      diffRuns.push(open - bare);
    }
    const bare = Math.min(...bareRuns);
    const open = Math.min(...openRuns);
    const lattice = Math.max(Math.min(...diffRuns), 0);
    cells.push(side ** 4);
    openTimes.push(open);
    latticeTimes.push(lattice);
    log(
      `  ${String(side).padStart(4)}  ${String(side ** 4).padStart(8)}  ${String(bare).padStart(18)}  ${String(open).padStart(8)}  ${String(lattice).padStart(11)}`,
    );
  }
  log("");

  // The small lattices cost less than the difference between two runs can
  // resolve, so the fit uses the sides whose lattice cost is above the noise.
  const usable = latticeTimes
    .map((t, i) => ({ t, c: cells[i], o: openTimes[i] }))
    .filter((x) => x.t >= 20);
  if (usable.length >= 3) {
    const s = scaling(usable.map((x) => x.c), usable.map((x) => x.t));
    log(`  the lattice's own cost: ${s.e.toFixed(2)}  ${s.text}`);
    const sOpen = scaling(usable.map((x) => x.c), usable.map((x) => x.o));
    log(`  the cost of opening the store: ${sOpen.e.toFixed(2)}  ${sOpen.text}`);
    log(`  fitted over the sides whose lattice cost is above the noise (${usable.length} of ${sides.length}).`);
  } else {
    log("  the lattice's own cost: not separable - every side measured is below the");
    log("  difference between two runs, so there is no scaling law to fit.");
  }
  log(
    `  the store stops being usable in reasonable time when the lattice costs`,
  );
  log(
    `  more than a caller is willing to wait: side ${sides[sides.length - 1]} is`,
  );
  log(
    `  ${cells[cells.length - 1]} cells and takes ${openTimes[openTimes.length - 1]} ms to open, and the`,
  );
  log(
    `  lattice may be built up to side 215, which is ${(215 ** 4).toExponential(2)} cells. The limit is that the`,
  );
  log(
    `  cells are held in one flat array indexed by a 32-bit Int, so what runs out`,
  );
  log(
    `  first is the machine, not the address space.`,
  );
  log("");
}

main();
