// The duplicate-code detector.
//
//   node qa/dup.mjs [min-lines]
//
// The same block of code in two places is the same bug waiting to happen
// twice, and it is the reason two halves of a project drift apart. This is
// the jscpd idea, small enough to read in one sitting and with no dependency
// to install.
//
// The comparison is on **normalised** lines: comments and blank lines are
// dropped, and the whitespace inside a line is collapsed, so two copies that
// differ only in their indentation are still two copies. A window of
// `min-lines` consecutive normalised lines is hashed, and a window that
// appears in two places is a duplicate.
//
// The report is a *measure*, not an accusation: a project with a table of
// error codes and a project with two copies of a loop are not the same kind
// of problem, and the report says where each one is so a reader can judge.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { ROOT, sourceFiles, log } from "./lib.mjs";

/** The smallest block worth reporting. */
const DEFAULT_MIN = 6;

/** A line, normalised: no comment, no leading or trailing space. */
function normalise(line) {
  const trimmed = line.trim();
  if (trimmed === "") return null;
  if (trimmed.startsWith("//")) return null;
  return trimmed.replace(/\s+/g, " ");
}

function main() {
  const minLines = Number(process.argv[2]) || DEFAULT_MIN;
  const files = sourceFiles();
  const windows = new Map();

  files.forEach((file) => {
    const rel = path.relative(ROOT, file);
    const isTest = /_test\.mbt$/.test(file);
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    const norm = [];
    const at = [];
    lines.forEach((line, i) => {
      const n = normalise(line);
      if (n !== null) {
        norm.push(n);
        at.push(i + 1);
      }
    });
    for (let i = 0; i + minLines <= norm.length; i++) {
      const slice = norm.slice(i, i + minLines).join("\n");
      const hash = crypto.createHash("sha1").update(slice).digest("hex");
      if (!windows.has(hash)) windows.set(hash, []);
      windows.get(hash).push({ file: rel, line: at[i], isTest });
    }
  });

  // A window that appears in two places is a duplicate; more than one
  // occurrence of the same block in the same file counts once.
  const blocks = [];
  for (const [, places] of windows) {
    const byFile = new Map();
    for (const p of places) {
      if (!byFile.has(p.file)) byFile.set(p.file, p);
    }
    if (byFile.size > 1) {
      const first = places[0];
      blocks.push({
        lines: minLines,
        files: [...byFile.values()],
        code: places[0].file,
        isTest: first.isTest,
      });
    }
  }

  // Merge the windows that are really one longer block: two windows of the
  // same code that overlap are one duplicate, not two.
  blocks.sort((a, b) => a.files[0].file.localeCompare(b.files[0].file) || a.files[0].line - b.files[0].line);
  const merged = [];
  for (const b of blocks) {
    const last = merged[merged.length - 1];
    if (
      last &&
      last.files.length === b.files.length &&
      last.files.every((f, i) => f.file === b.files[i].file && Math.abs(f.line - b.files[i].line) < minLines)
    ) {
      last.lines += 1;
      continue;
    }
    merged.push({ ...b });
  }

  const testBlocks = merged.filter((b) => b.isTest);
  const codeBlocks = merged.filter((b) => !b.isTest);
  const dupLines = merged.reduce((a, b) => a + b.lines, 0);

  log("duplicate code");
  log("");
  log(`  ${files.length} files, blocks of ${minLines}+ normalised lines`);
  log("");
  log(`  ${merged.length} duplicated block(s): ${codeBlocks.length} in library code, ${testBlocks.length} in tests`);
  log(`  ${dupLines} duplicated lines in total`);
  log("");
  if (codeBlocks.length > 0) {
    log("  in library code:");
    for (const b of codeBlocks.sort((x, y) => y.lines - x.lines).slice(0, 15)) {
      const where = b.files.map((f) => `${f.file}:${f.line}`).join("  ==  ");
      log(`    ${String(b.lines).padStart(4)} lines   ${where}`);
    }
    log("");
  }
  if (testBlocks.length > 0) {
    log("  in tests (the first ten):");
    for (const b of testBlocks.sort((x, y) => y.lines - x.lines).slice(0, 10)) {
      const where = b.files.map((f) => `${f.file}:${f.line}`).join("  ==  ");
      log(`    ${String(b.lines).padStart(4)} lines   ${where}`);
    }
    log("");
  }
  if (merged.length === 0) log("  nothing duplicated");
}

main();
