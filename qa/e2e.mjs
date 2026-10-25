// The end-to-end coverage map.
//
//   node qa/e2e.mjs
//
// The project has 422 unit tests, 103 CLI checks, 45 window checks and a
// Gherkin suite. Those are four numbers, and none of them says whether the
// thing a person actually does is covered. A suite can be large and still
// miss a command entirely.
//
// So this map is built from the *command surface*, and the surface is read
// out of the source rather than written down here. A hand-written table of
// commands is a table that rots: it starts claiming the CLIs do less than
// they do the first time a command is added, and the first thing it does
// with that is to stop noticing a command nobody tests.
//
// For each CLI the tool finds the commands in its own source - the dotted
// ones (`.status`) and the bare verbs (`put`) - and then looks for each in
// every layer.
//
// What a cell means, and how a hit is found:
//
//   unit       the word appears in a MoonBit test file
//   gherkin    the word appears in a `.feature` file
//   cli-smoke  the word appears *quoted*, because that is how a command
//              reaches a process - `run("memory", ["put", "k", "v"])`
//   gui-smoke  the same
//
// A bare word in prose is not a hit in the smoke suites, and a quoted word
// is the only thing that counts there. That is deliberately strict: a cell
// that says "yes" should mean the command was really exercised.

import fs from "node:fs";
import path from "node:path";
import { ROOT, sourceFiles, log } from "./lib.mjs";

/** Where each CLI's commands are written. */
const CLIS = [
  { cli: "cmd/main", sources: ["cmd/main/main.mbt"] },
  { cli: "cmd/persist", sources: ["cmd/persist/main.mbt"] },
  { cli: "cmd/memory", sources: ["cmd/memory/main.mbt", "src/tesseract_memory_cli/cli.mbt"] },
  { cli: "cmd/memory_db", sources: ["cmd/memory_db/main.mbt", "src/tesseract_memory_cli/cli.mbt"] },
  { cli: "cmd/sa", sources: ["cmd/sa/main.mbt"] },
];

/** The SQL statement kinds cmd/main accepts, which are not spelled as commands. */
const SQL_VERBS = ["INSERT", "SELECT", "UPDATE", "DELETE"];

/** Escapes a string for use inside a regular expression. */
function esc(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The source of a file, without its comment lines. */
function code(file) {
  return fs
    .readFileSync(file, "utf8")
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

/** The commands a CLI answers to, read out of its own source. */
function commandsOf(entry) {
  const text = entry.sources
    .map((s) => {
      const p = path.join(ROOT, s);
      return fs.existsSync(p) ? code(p) : "";
    })
    .join("\n");

  const dotted = new Set();
  const bare = new Set();
  for (const m of text.matchAll(/"(\.[a-z][a-z-]*)/g)) dotted.add(m[1]);
  for (const m of text.matchAll(/\b(?:verb|arg|cmd|command)\s*==\s*"([a-z][a-z-]*)"/g)) bare.add(m[1]);
  for (const m of text.matchAll(/\b(?:verb|arg|cmd|command)\s*==\s*"([a-z][a-z-]*)"\s*\|\|\s*"/g)) {
    // The first alternative of `a == "x" || a == "y"`; the second is caught
    // by the same pattern on the next pass, but only if it starts with the
    // same word - so the alternation is read out by hand here.
    bare.add(m[1]);
  }
  return { dotted: [...dotted].sort(), bare: [...bare].sort() };
}

/**
 * How many scenarios a feature file runs.
 *
 * A `Scenario Outline` is one scenario until its `Examples` table is filled
 * in, and each row of that table is a run in its own right. The header row
 * of the table is not a run, so it is not counted.
 */
function scenarioCount(text) {
  const lines = text.split(/\r?\n/);
  let runs = 0;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*Scenario Outline:/.test(line)) {
      // The outline's own declaration is not a run of its own once its table
      // has rows: one row is one run.
      let rows = 0;
      let inTable = false;
      let seenHeader = false;
      for (let k = i + 1; k < lines.length; k++) {
        if (/^\s*Scenario/.test(lines[k])) break;
        if (/^\s*Examples:/.test(lines[k])) {
          inTable = true;
          seenHeader = false;
          continue;
        }
        if (!inTable) continue;
        if (!/^\s*\|/.test(lines[k])) {
          inTable = false;
          continue;
        }
        if (!seenHeader) {
          seenHeader = true;
          continue;
        }
        rows++;
      }
      runs += rows > 0 ? rows : 1;
      i++;
      continue;
    }
    if (/^\s*Scenario:/.test(line)) runs++;
    i++;
  }
  return runs;
}

/** The layers, and where their artefacts are. */
function layers() {
  const unit = sourceFiles().filter((f) => /_test\.mbt$/.test(f));
  const featureDir = path.join(ROOT, "qa", "features");
  const features = fs.existsSync(featureDir)
    ? fs
        .readdirSync(featureDir)
        .filter((n) => n.endsWith(".feature"))
        .map((n) => path.join(featureDir, n))
    : [];
  const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "");

  return [
    {
      id: "unit",
      what: "the MoonBit test suite",
      text: unit.map((f) => fs.readFileSync(f, "utf8")).join("\n"),
      count: unit.reduce(
        (n, f) => n + (fs.readFileSync(f, "utf8").match(/^\s*test\s+"/gm) || []).length,
        0,
      ),
      unit: "tests",
      quoted: false,
    },
    {
      id: "gherkin",
      what: "the Gherkin features",
      text: features.map((f) => fs.readFileSync(f, "utf8")).join("\n"),
      count: features.reduce(
        (n, f) => n + scenarioCount(fs.readFileSync(f, "utf8")),
        0,
      ),
      unit: "scenarios",
      quoted: false,
    },
    {
      id: "cli-smoke",
      what: "the CLI smoke suite",
      text: read(path.join(ROOT, "cli-smoke.mjs")),
      count: (read(path.join(ROOT, "cli-smoke.mjs")).match(/^\s*(?:await\s+)?check\(/gm) || []).length,
      unit: "checks",
      quoted: true,
    },
    {
      id: "gui-smoke",
      what: "the window smoke suite",
      text: read(path.join(ROOT, "gui-smoke.mjs")),
      count: (read(path.join(ROOT, "gui-smoke.mjs")).match(/^\s*(?:await\s+)?check\(/gm) || []).length,
      unit: "checks",
      quoted: true,
    },
  ];
}

/**
 * How many times a command is exercised in a layer.
 *
 * A dotted command is matched as a dotted command, because that is how it is
 * typed. A bare command in a smoke suite has to be quoted, because that is
 * how it reaches a process.
 */
function hits(text, command, quoted) {
  if (command.startsWith(".")) {
    return (text.match(new RegExp(esc(command) + "\\b", "g")) || []).length;
  }
  if (command === command.toUpperCase()) {
    return (text.match(new RegExp("\\b" + esc(command) + "\\b", "g")) || []).length;
  }
  if (quoted) {
    // A command reaches a process inside a quoted argv entry, and that entry
    // may carry arguments of its own - `"search-all cat"` is one word to the
    // program, not two. The token has to be *inside* the quotes, with word
    // boundaries on both sides so `forget` is not a hit for `get`.
    return (text.match(new RegExp("[\"'][^\"']*\\b" + esc(command) + "\\b[^\"']*[\"']", "g")) || []).length;
  }
  return (text.match(new RegExp("\\b" + esc(command) + "\\b", "g")) || []).length;
}

function main() {
  const all = layers();

  log("end-to-end coverage map");
  log("");
  log("  the layers");
  for (const l of all) {
    log(`  ${l.id.padEnd(10)} ${String(l.count).padStart(4)}  ${l.unit.padEnd(10)}  ${l.what}`);
  }
  log("");

  log("  the command surface, read out of the source");
  log(`  ${"cli".padEnd(14)} ${"command".padEnd(13)} ${all.map((l) => l.id.padEnd(10)).join("")}`);

  const uncovered = [];
  const unitOnly = [];
  let total = 0;

  for (const entry of CLIS) {
    const { dotted, bare } = commandsOf(entry);
    const commands = [
      ...dotted,
      ...bare,
      ...(entry.cli === "cmd/main" ? SQL_VERBS : []),
    ];
    for (const command of commands) {
      total++;
      const counts = all.map((l) => hits(l.text, command, l.quoted));
      const row = counts.map((c) => (c > 0 ? "yes" : "-").padEnd(10)).join("");
      log(`  ${entry.cli.padEnd(14)} ${command.padEnd(13)} ${row}`);
      const behavioural = counts.slice(1).filter((c) => c > 0).length;
      if (behavioural === 0) {
        if (counts[0] > 0) unitOnly.push(`${entry.cli} ${command}`);
        else uncovered.push(`${entry.cli} ${command}`);
      }
    }
  }
  log("");

  log(`  ${total} commands across ${CLIS.length} CLIs`);
  log(`  ${uncovered.length} exercised by no layer at all`);
  for (const u of uncovered) log(`    ${u}`);
  log(`  ${unitOnly.length} exercised only by the unit suite`);
  for (const u of unitOnly) log(`    ${u}`);
  log("");

  process.exit(uncovered.length === 0 ? 0 : 1);
}

main();
