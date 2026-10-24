// The step definitions the `.feature` files are run with.
//
//   qa/features/steps/definitions.mjs
//
// A step here is a promise: "run this program, and check what it said". Every
// definition ends in an assertion about something observable - the output on
// stdout, the output on stderr, the exit code, or a file on disk. A definition
// that asserts nothing is not a step, it is a line of prose with a colon in it.
//
// The two shapes of step are:
//
//   - **action** steps that run a binary, and
//   - **assertion** steps that read what the last run said.
//
// The action steps take their arguments from a table under the step, so a
// scenario can say what to run without the runner having to know what any
// particular command means. `{dir}` in a table cell is the scenario's own
// scratch directory, and `{root}` is the repository.

import fs from "node:fs";
import path from "node:path";
import { ROOT, build, run, classify } from "../../lib.mjs";

/**
 * The command lines the features may drive, and the package behind each.
 *
 * `cmd/gui` is not here: it is a Proton desktop window with no
 * non-interactive mode, so there is nothing to run and nothing to observe.
 */
export const CLIS = {
  tesseract: "cmd/main",
  persistence: "cmd/persist",
  memory: "cmd/memory",
  "durable memory": "cmd/memory_db",
  "static analysis": "cmd/sa",
};

/** The binaries that have been built already, so the sweep builds each once. */
const built = new Map();

function ensureBuilt(pkg) {
  if (built.has(pkg)) return built.get(pkg);
  const p = build(pkg);
  built.set(pkg, p);
  return p;
}

/**
 * Fills the placeholders a step carries.
 *
 * `{dir}` is the scenario's own scratch directory and `{root}` is the
 * repository, so a step can name a file it means to write or a file it means
 * to read without knowing where anything lives.
 */
export function fill(text, ctx) {
  return String(text).replace(/\{dir\}/g, ctx.dir).replace(/\{root\}/g, ROOT);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function out(ctx) {
  return ctx.last ? ctx.last.out : "";
}

function err(ctx) {
  return ctx.last ? ctx.last.err : "";
}

function lastLine(ctx) {
  const lines = out(ctx).split(/\r?\n/).filter((l) => l.trim() !== "");
  return lines.length === 0 ? "" : lines[lines.length - 1].trim();
}

/** The quoted pieces of a piece of text, in order. */
function quoted(text) {
  const out = [];
  const re = /"([^"]*)"/g;
  let m;
  while ((m = re.exec(text)) !== null) out.push(m[1]);
  return out;
}

/** The first capture of a pattern in the output, or null. */
function capture(ctx, re) {
  const m = re.exec(out(ctx));
  return m ? m[1] : null;
}

// ---------------------------------------------------------------------------
// The action steps
// ---------------------------------------------------------------------------

/** `the "memory" CLI is built` - the binary exists and can be run. */
function cliIsBuilt(ctx, params) {
  const pkg = CLIS[params.cli];
  assert(pkg, `there is no CLI called "${params.cli}"`);
  const exe = ensureBuilt(pkg);
  assert(
    fs.existsSync(exe),
    `the "${params.cli}" binary was not produced at ${exe}`,
  );
}

/**
 * `I run the "memory" CLI:` with a table of arguments under it.
 *
 * Every row of the table is one argument, so a statement with spaces in it
 * stays one argument.
 */
function runWithTable(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, []));
}

/**
 * `I run the "memory" CLI with the file "{dir}/notes.db":`
 *
 * The options come first and the commands follow, which is the order the
 * command line wants them in.
 */
function runWithFile(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, ["--file", params.path]));
}

/** `I run the "memory" CLI with the file "..." and the index "...":` */
function runWithFileAndIndex(ctx, params) {
  drive(
    ctx,
    pkgOf(params),
    commandsOf(ctx, ["--file", params.path, "--index", params.index]),
  );
}

/** `I run the "memory" CLI with a capacity of 3:` */
function runWithCapacity(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, ["--capacity", String(params.n)]));
}

/** `I run the "memory" CLI on a manual clock:` */
function runOnManualClock(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, ["--manual-clock"]));
}

/** `I run the "memory" CLI in the scope "work":` */
function runInScope(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, ["--scope", params.scope]));
}

/** `I run the "tesseract" CLI with a lattice of 4 cells per axis:` */
function runWithLattice(ctx, params) {
  drive(ctx, pkgOf(params), commandsOf(ctx, ["--side", String(params.n)]));
}

/**
 * `I store the captured scan in "{dir}/scan.db"`
 *
 * The scan store reads the capture that is in the scenario's own directory,
 * and writes the run into the database it is given.
 */
function storeScan(ctx, params) {
  drive(ctx, "cmd/sa", ["store", path.join(ctx.dir, "scan.tsv"), params.db]);
}

/** `I show the stored run in "{dir}/scan.db"` */
function showRun(ctx, params) {
  drive(ctx, "cmd/sa", ["show", params.db]);
}

/** `I list the stored runs in "{dir}/scan.db"` */
function listRuns(ctx, params) {
  drive(ctx, "cmd/sa", ["runs", params.db]);
}

/** `I list the files of the stored run in "{dir}/scan.db"` */
function listFiles(ctx, params) {
  drive(ctx, "cmd/sa", ["files", params.db]);
}

/** `I run the "memory" CLI with the arguments "a" "b"` - the arguments inline. */
function runWithArguments(ctx, params) {
  drive(ctx, pkgOf(params), quoted(params.rest).map((a) => fill(a, ctx)));
}

/** The package a step names, or a complaint that it named none. */
function pkgOf(params) {
  const pkg = CLIS[params.cli];
  assert(pkg, `there is no CLI called "${params.cli}"`);
  ensureBuilt(pkg);
  return pkg;
}

/** The commands under a step, after the options it asked for. */
function commandsOf(ctx, options) {
  const table = ctx.table ?? [];
  const args = [...options];
  for (const row of table) {
    assert(
      row.length === 1,
      `every row of the table under a run step must be one argument, got ${row.length}`,
    );
    args.push(fill(row[0], ctx));
  }
  return args;
}

/**
 * Runs a binary and keeps what it said.
 *
 * A program that hangs or dies is a failure of the scenario, not a result to
 * assert on: the three answers the harness can give are kept apart so that a
 * crash is never mistaken for a refusal the product meant to make.
 */
function drive(ctx, pkg, args) {
  const r = run(pkg, args, ctx.dir);
  const c = classify(r);
  if (c !== null) {
    throw new Error(
      `the ${pkg} run did not finish normally: ${c.kind} (${c.detail})`,
    );
  }
  ctx.last = { ...r, pkg, args };
}

/**
 * `a captured static analysis scan is available`.
 *
 * The repository keeps a scan of a real project under
 * `src/tesseract_sa/testdata_scan.tsv`. It is copied into the scenario's own
 * scratch directory, so the store is exercised on a scan with real findings
 * rather than on a file invented for the test.
 */
function scanIsAvailable(ctx) {
  const source = path.join(ROOT, "src", "tesseract_sa", "testdata_scan.tsv");
  const target = path.join(ctx.dir, "scan.tsv");
  assert(fs.existsSync(source), `there is no captured scan at ${source}`);
  fs.copyFileSync(source, target);
  const st = fs.statSync(target);
  assert(st.isFile() && st.size > 0, "the captured scan did not arrive in the scratch directory");
}

// ---------------------------------------------------------------------------
// The assertion steps
// ---------------------------------------------------------------------------

function runSucceeded(ctx) {
  assert(ctx.last, "nothing has been run yet");
  assert(
    ctx.last.code === 0,
    `the run exited with ${ctx.last.code}, not 0`,
  );
}

function outputContains(ctx, params) {
  const text = params.text;
  assert(
    out(ctx).includes(text),
    `the output does not contain ${JSON.stringify(text)}`,
  );
}

function outputDoesNotContain(ctx, params) {
  const text = params.text;
  assert(
    !out(ctx).includes(text),
    `the output contains ${JSON.stringify(text)}, which it should not`,
  );
}

function lastLineContains(ctx, params) {
  const line = lastLine(ctx);
  assert(
    line.includes(params.text),
    `the last line of the output is ${JSON.stringify(line)}, which does not contain ${JSON.stringify(params.text)}`,
  );
}

function lastLineDoesNotContain(ctx, params) {
  const line = lastLine(ctx);
  assert(
    !line.includes(params.text),
    `the last line of the output is ${JSON.stringify(line)}, which contains ${JSON.stringify(params.text)}`,
  );
}

function errorOutputContains(ctx, params) {
  assert(
    err(ctx).includes(params.text),
    `the error output does not contain ${JSON.stringify(params.text)}`,
  );
}

function exitCodeIs(ctx, params) {
  assert(ctx.last, "nothing has been run yet");
  assert(
    ctx.last.code === Number(params.n),
    `the run exited with ${ctx.last.code}, not ${params.n}`,
  );
}

/** The number of rows the last query answered with. */
function queryReturns(ctx, params) {
  const n = capture(ctx, /查询结果\s*\((\d+)\s*条记录\)/);
  assert(n !== null, "the output does not say how many records the query returned");
  assert(
    Number(n) === Number(params.n),
    `the query returned ${n} records, not ${params.n}`,
  );
}

function databaseHoldsRecords(ctx, params) {
  const n = capture(ctx, /records\s*:\s*(\d+)/);
  assert(n !== null, "the output does not say how many records the database holds");
  assert(
    Number(n) === Number(params.n),
    `the database holds ${n} records, not ${params.n}`,
  );
}

function databaseHoldsDigits(ctx, params) {
  const n = capture(ctx, /digits\s*:\s*(\d+)/);
  assert(n !== null, "the output does not say how many digits the database holds");
  assert(
    Number(n) === Number(params.n),
    `the database holds ${n} digits, not ${params.n}`,
  );
}

function latticeHasSide(ctx, params) {
  const n = capture(ctx, /lattice\s*:\s*(\d+)x/);
  assert(n !== null, "the output does not say the shape of the lattice");
  assert(
    Number(n) === Number(params.n),
    `the lattice has ${n} cells per axis, not ${params.n}`,
  );
}

/** The keys the memory lists, as one comma-separated line. */
function keysAre(ctx, params) {
  const line = lastLine(ctx);
  assert(
    line === params.keys,
    `the keys are ${JSON.stringify(line)}, not ${JSON.stringify(params.keys)}`,
  );
}

function fileExists(ctx, params) {
  const target = path.join(ctx.dir, params.name);
  assert(fs.existsSync(target), `there is no file named ${params.name} in the scratch directory`);
}

function fileContains(ctx, params) {
  const target = path.join(ctx.dir, params.name);
  assert(fs.existsSync(target), `there is no file named ${params.name} in the scratch directory`);
  const text = fs.readFileSync(target, "utf8");
  assert(
    text.includes(params.text),
    `the file ${params.name} does not contain ${JSON.stringify(params.text)}`,
  );
}

// ---------------------------------------------------------------------------
// The definitions
// ---------------------------------------------------------------------------

export const STEPS = [
  // the action steps
  { pattern: `the "<cli>" CLI is built`, fn: cliIsBuilt },
  { pattern: `I run the "<cli>" CLI:`, fn: runWithTable },
  {
    pattern: `I run the "<cli>" CLI with the file "<path>":`,
    fn: runWithFile,
  },
  {
    pattern: `I run the "<cli>" CLI with the file "<path>" and the index "<index>":`,
    fn: runWithFileAndIndex,
  },
  {
    pattern: `I run the "<cli>" CLI with a capacity of <n>:`,
    fn: runWithCapacity,
  },
  {
    pattern: `I run the "<cli>" CLI on a manual clock:`,
    fn: runOnManualClock,
  },
  {
    pattern: `I run the "<cli>" CLI in the scope "<scope>":`,
    fn: runInScope,
  },
  {
    pattern: `I run the "<cli>" CLI with a lattice of <n> cells per axis:`,
    fn: runWithLattice,
  },
  {
    pattern: `I run the "<cli>" CLI with the arguments <rest>`,
    fn: runWithArguments,
  },
  {
    pattern: `a captured static analysis scan is available`,
    fn: scanIsAvailable,
  },
  {
    pattern: `I store the captured scan in "<db>"`,
    fn: storeScan,
  },
  { pattern: `I show the stored run in "<db>"`, fn: showRun },
  { pattern: `I list the stored runs in "<db>"`, fn: listRuns },
  { pattern: `I list the files of the stored run in "<db>"`, fn: listFiles },

  // the assertion steps
  { pattern: `the run succeeds`, fn: runSucceeded },
  { pattern: `the output contains "<text>"`, fn: outputContains },
  {
    pattern: `the output does not contain "<text>"`,
    fn: outputDoesNotContain,
  },
  {
    pattern: `the last output line contains "<text>"`,
    fn: lastLineContains,
  },
  {
    pattern: `the last output line does not contain "<text>"`,
    fn: lastLineDoesNotContain,
  },
  {
    pattern: `the error output contains "<text>"`,
    fn: errorOutputContains,
  },
  { pattern: `the exit code is <n>`, fn: exitCodeIs },
  { pattern: `the query returns <n> record`, fn: queryReturns },
  { pattern: `the query returns <n> records`, fn: queryReturns },
  { pattern: `the database holds <n> record`, fn: databaseHoldsRecords },
  { pattern: `the database holds <n> records`, fn: databaseHoldsRecords },
  { pattern: `the database holds <n> digit`, fn: databaseHoldsDigits },
  { pattern: `the database holds <n> digits`, fn: databaseHoldsDigits },
  { pattern: `the lattice has <n> cells per axis`, fn: latticeHasSide },
  { pattern: `the keys are "<keys>"`, fn: keysAre },
  { pattern: `the file "<name>" exists`, fn: fileExists },
  {
    pattern: `the file "<name>" contains "<text>"`,
    fn: fileContains,
  },
];
