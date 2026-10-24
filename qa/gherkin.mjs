// The Gherkin dimension of the QA sweep.
//
//   node qa/gherkin.mjs
//
// The unit tests say the library does what its functions say. They do not say
// what a person *sees* when they type a command into a terminal, and that is
// the part that breaks: a CLI can pass every unit test and still answer the
// question it was asked wrongly.
//
// So this runs `.feature` files. Each one states a behaviour the way a person
// would say it - "when I insert a key and query it back, I get that key" - and
// every step of it is a step against the **built binaries**, run as real
// processes with real arguments. There is no mocking and no in-process call
// into the library: a step that cannot be answered by looking at what a
// program printed is not a step.
//
// The parser is here, in the file, because a Gherkin runner without a parser
// is a list of strings. It understands `Feature`, `Background`, `Scenario`,
// `Scenario Outline` with `Examples`, and the steps between them. A step is
// matched against the definitions in `qa/features/steps/definitions.mjs`; a
// step that matches no definition is a failure, never a pass.
//
// Every scenario gets a scratch directory of its own, so a file one scenario
// writes cannot be seen by the next one, and the directory is removed when
// the scenario ends.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ROOT, log, scratch, cleanup } from "./lib.mjs";
import { STEPS, fill } from "./features/steps/definitions.mjs";

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

const STEP_WORDS = new Set(["Given", "When", "Then", "And", "But"]);

/** Whether a line is a data table row. */
function isTableRow(line) {
  return line.startsWith("|") && line.endsWith("|") && line.length >= 2;
}

/**
 * The cells of one table row.
 *
 * A cell may hold a `|` of its own, written `\|`, because the values here are
 * SQL statements and a statement may well contain a pipe.
 */
function splitRow(line) {
  const inner = line.slice(1, -1);
  const cells = [];
  let cur = "";
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === "\\" && inner[i + 1] === "|") {
      cur += "|";
      i++;
      continue;
    }
    if (ch === "|") {
      cells.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  cells.push(cur.trim());
  return cells;
}

/**
 * Reads one `.feature` file.
 *
 * The shape it returns is the one the executor wants: a feature with a
 * background and a list of scenarios, each scenario a list of steps, each step
 * its text and the table that may hang under it.
 */
export function parseFeature(text, file) {
  const lines = text.split(/\r?\n/);
  const feature = {
    file,
    name: file,
    description: [],
    background: [],
    scenarios: [],
  };
  let tags = [];
  let section = null;
  let scenario = null;
  let lastKeyword = "Given";
  let i = 0;

  while (i < lines.length) {
    const line = lines[i].trim();

    if (line === "" || line.startsWith("#")) {
      i++;
      continue;
    }
    if (line.startsWith("@")) {
      tags.push(...line.split(/\s+/).filter(Boolean));
      i++;
      continue;
    }
    if (/^Feature\s*:/.test(line)) {
      feature.name = line.replace(/^Feature\s*:\s*/, "").trim();
      section = "feature";
      i++;
      continue;
    }
    if (/^Background\s*:/.test(line)) {
      section = "background";
      i++;
      continue;
    }
    if (/^Examples\s*:/.test(line)) {
      if (!scenario) throw new Error(`${file}: Examples: outside a scenario`);
      i++;
      const rows = [];
      while (i < lines.length && isTableRow(lines[i].trim())) {
        rows.push(splitRow(lines[i].trim()));
        i++;
      }
      if (rows.length === 0) {
        throw new Error(`${file}: Examples: has no table under it`);
      }
      scenario.examples.push({ header: rows[0], rows: rows.slice(1) });
      section = "examples";
      continue;
    }
    let m;
    if ((m = /^Scenario Outline\s*:\s*(.*)$/.exec(line))) {
      scenario = {
        kind: "outline",
        name: m[1].trim(),
        tags: [...tags],
        steps: [],
        examples: [],
      };
      feature.scenarios.push(scenario);
      tags = [];
      section = "scenario";
      i++;
      continue;
    }
    if ((m = /^Scenario\s*:\s*(.*)$/.exec(line))) {
      scenario = {
        kind: "scenario",
        name: m[1].trim(),
        tags: [...tags],
        steps: [],
        examples: [],
      };
      feature.scenarios.push(scenario);
      tags = [];
      section = "scenario";
      i++;
      continue;
    }
    if (isTableRow(line)) {
      // A table belongs to the step above it.
      const owner =
        section === "background" ? { steps: feature.background } : scenario;
      if (!owner) throw new Error(`${file}: a table outside a scenario`);
      const last = owner.steps[owner.steps.length - 1];
      if (!last) throw new Error(`${file}: a table with no step above it`);
      const rows = [];
      while (i < lines.length && isTableRow(lines[i].trim())) {
        rows.push(splitRow(lines[i].trim()));
        i++;
      }
      last.table = rows;
      continue;
    }
    if ((m = /^([A-Za-z]+)\s+(.*)$/.exec(line)) && STEP_WORDS.has(m[1])) {
      // `And` and `But` carry the meaning of the step they follow.
      const keyword = m[1] === "And" || m[1] === "But" ? lastKeyword : m[1];
      lastKeyword = keyword;
      const step = { keyword, text: m[2].trim(), table: null };
      if (section === "background") feature.background.push(step);
      else if (scenario) scenario.steps.push(step);
      else throw new Error(`${file}: a step outside a scenario`);
      i++;
      continue;
    }
    if (section === "feature") feature.description.push(line);
    i++;
  }
  return feature;
}

/**
 * Fills `<name>` in a piece of text from an example row.
 *
 * A name that the row does not have is left alone: a `<` that is not a
 * placeholder is not one, and turning it into nothing would silently change
 * what the step says.
 */
function substitute(text, map) {
  return text.replace(/<([^<>]+)>/g, (whole, name) =>
    Object.prototype.hasOwnProperty.call(map, name) ? map[name] : whole,
  );
}

/**
 * The scenarios a feature really has.
 *
 * A `Scenario Outline` is one scenario per example row, with the row's values
 * written into the name, the steps and the tables.
 */
export function expand(feature) {
  const out = [];
  for (const scenario of feature.scenarios) {
    if (scenario.kind !== "outline") {
      out.push(scenario);
      continue;
    }
    for (const example of scenario.examples) {
      for (const row of example.rows) {
        const map = {};
        example.header.forEach((h, idx) => {
          map[h] = row[idx] ?? "";
        });
        out.push({
          kind: "scenario",
          name: substitute(scenario.name, map),
          tags: scenario.tags,
          examples: [],
          steps: scenario.steps.map((s) => ({
            keyword: s.keyword,
            text: substitute(s.text, map),
            table: s.table ? s.table.map((r) => r.map((c) => substitute(c, map))) : null,
          })),
        });
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The step matcher
// ---------------------------------------------------------------------------

/**
 * Turns a step pattern into a regular expression.
 *
 * A `<name>` inside quotes captures whatever is in the quotes, so a value may
 * hold spaces; a bare `<name>` captures one word. The two forms are told apart
 * by the quotes, which is why the quotes are part of the pattern and not of
 * the capture. The name `rest` is special: it captures the whole tail of the
 * step, for the few steps whose argument is a list.
 */
export function patternToRegex(pattern) {
  let source = "";
  const re = /"\<(\w+)\>"|\<(\w+)\>/g;
  let last = 0;
  let m;
  while ((m = re.exec(pattern)) !== null) {
    source += escapeRegex(pattern.slice(last, m.index));
    if (m[1] !== undefined) source += `"(?<${m[1]}>[^"]*)"`;
    else if (m[2] === "rest") source += `(?<rest>.+)`;
    else source += `(?<${m[2]}>\\S+)`;
    last = m.index + m[0].length;
  }
  source += escapeRegex(pattern.slice(last));
  return new RegExp(`^${source}$`);
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const COMPILED = STEPS.map((s) => ({ ...s, regex: patternToRegex(s.pattern) }));

/** The definition a step text matches, and the values it carries. */
function matchStep(text) {
  for (const def of COMPILED) {
    const m = def.regex.exec(text);
    if (m) return { def, params: m.groups ?? {} };
  }
  return null;
}

// ---------------------------------------------------------------------------
// The executor
// ---------------------------------------------------------------------------

/** A step that failed, with the state of the scenario at the time. */
class StepFailure extends Error {
  constructor(step, cause, ctx) {
    super(cause.message);
    this.step = step;
    this.cause = cause;
    this.ctx = ctx;
  }
}

/**
 * Runs one scenario.
 *
 * The background runs first, for every scenario, because that is what a
 * `Background:` means.
 */
async function executeScenario(feature, scenario, dir) {
  const ctx = {
    dir,
    feature,
    scenario,
    last: null,
    table: null,
    executed: 0,
  };
  const steps = [...feature.background, ...scenario.steps];
  for (const step of steps) {
    ctx.table = step.table;
    ctx.executed++;
    const hit = matchStep(step.text);
    if (!hit) {
      throw new StepFailure(step, new Error("no step definition matches this step"), ctx);
    }
    const params = {};
    for (const [k, v] of Object.entries(hit.params)) {
      params[k] = fill(v, ctx);
    }
    try {
      await hit.def.fn(ctx, params, step);
    } catch (e) {
      throw new StepFailure(step, e, ctx);
    }
  }
  return ctx;
}

// ---------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------

/** The output of the last run, so a failure can show what was actually said. */
function observed(ctx) {
  if (!ctx || !ctx.last) return { out: "", err: "" };
  return { out: ctx.last.out, err: ctx.last.err };
}

function tail(text, lines) {
  const kept = text.split(/\r?\n/);
  const shown = kept.length > lines ? kept.slice(kept.length - lines) : kept;
  return shown.map((l) => `      ${l}`).join("\n");
}

/** What a failing scenario looked like from the outside. */
function reportFailure(failure) {
  const { step, cause, ctx } = failure;
  const { out, err } = observed(ctx);
  log(`    FAIL  ${ctx.scenario.name}`);
  log(`          step     : ${step.keyword} ${step.text}`);
  log(`          why      : ${cause.message}`);
  if (ctx.last) {
    log(`          command  : ${ctx.last.pkg} ${ctx.last.args.join(" ")}`);
    log(`          exit code: ${ctx.last.code}`);
  }
  log("          stdout:");
  log(out.trim() ? tail(out, 20) : "      (nothing)");
  log("          stderr:");
  log(err.trim() ? tail(err, 20) : "      (nothing)");
}

// ---------------------------------------------------------------------------
// The sweep
// ---------------------------------------------------------------------------

export async function sweep() {
  const dir = path.join(ROOT, "qa", "features");
  const files = fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".feature"))
    .sort();

  if (files.length === 0) {
    log("no .feature files found in qa/features");
    return 1;
  }

  log("gherkin sweep");
  log("");

  let features = 0;
  let scenarios = 0;
  let steps = 0;
  let passed = 0;
  let failed = 0;
  const failures = [];

  for (const file of files) {
    const feature = parseFeature(fs.readFileSync(path.join(dir, file), "utf8"), file);
    features++;
    log(`  ${file}`);
    log(`    ${feature.name}`);

    for (const scenario of expand(feature)) {
      scenarios++;
      const scratchDir = scratch("gherkin");
      try {
        const ctx = await executeScenario(feature, scenario, scratchDir);
        steps += ctx.executed;
        passed++;
        log(`      PASS  ${scenario.name}  (${ctx.executed} steps)`);
      } catch (e) {
        if (e instanceof StepFailure) {
          steps += e.ctx.executed;
          failed++;
          failures.push(e);
          reportFailure(e);
        } else {
          failed++;
          log(`      FAIL  ${scenario.name}`);
          log(`          ${e.message}`);
        }
      } finally {
        cleanup(scratchDir);
      }
    }
    log("");
  }

  log("summary");
  log(`  features   ${features}`);
  log(`  scenarios  ${scenarios}   ${passed} passed, ${failed} failed`);
  log(`  steps      ${steps} executed`);
  if (failed === 0) {
    log("");
    log("  every scenario passed");
  } else {
    log("");
    log("  the failing scenarios:");
    for (const f of failures) {
      log(`    ${f.ctx.feature.file} > ${f.ctx.scenario.name}`);
    }
  }
  log("");

  return failed === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// The entry point
// ---------------------------------------------------------------------------

const invokedDirectly =
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);

if (invokedDirectly) {
  sweep()
    .then((code) => process.exit(code))
    .catch((e) => {
      log(`the sweep itself failed: ${e.stack ?? e.message}`);
      process.exit(1);
    });
}
