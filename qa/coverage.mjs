// Line coverage, measured.
//
//   node qa/coverage.mjs
//
// The numbers come from the compiler's own coverage data, read out of the
// Cobertura report the bundled reporter writes. The report is a file, so the
// numbers are reproducible and diffable — a coverage number that lives only in
// a terminal scrollback is a number nobody can check.
//
// Two things are reported separately, because they are two different things:
//
// - the **libraries** (`src/`), which are exercised by the in-process test
//   suite;
// - the **binaries** (`cmd/`), which have no in-process tests at all and are
//   exercised by `cli-smoke.mjs` instead. Their in-process coverage is zero
//   by construction, and reporting that as if it were a defect would be a
//   lie about what the number means.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ROOT, log } from "./lib.mjs";

const REPORT = path.join(ROOT, "cobertura.xml");

/** Parses the Cobertura report into { file: { valid, covered, rate } }. */
export function parseCobertura(file = REPORT) {
  const xml = fs.readFileSync(file, "utf8");
  const files = new Map();
  const classRe = /<class name="([^"]+)" filename="([^"]+)" line-rate="([\d.]+)">([\s\S]*?)<\/class>/g;
  let m;
  while ((m = classRe.exec(xml)) !== null) {
    const [, , filename, rate, body] = m;
    const lines = [...body.matchAll(/<line number="(\d+)" hits="(\d+)"\/>/g)];
    const covered = lines.filter(([, , hits]) => Number(hits) > 0).length;
    files.set(filename.replace(/\\/g, "/"), {
      valid: lines.length,
      covered,
      rate: Number(rate),
    });
  }
  const head = /<coverage lines-valid="(\d+)" lines-covered="(\d+)" line-rate="([\d.]+)"/.exec(xml);
  return {
    total: head
      ? { valid: Number(head[1]), covered: Number(head[2]), rate: Number(head[3]) }
      : { valid: 0, covered: 0, rate: 0 },
    files,
  };
}

/** The package a file belongs to: `src/tesseract_memory`, `cmd/memory`, ... */
function pkgOf(file) {
  const parts = file.split("/");
  if (parts[0] === "cmd") return parts.slice(0, 2).join("/");
  if (parts[0] === "src") return parts.slice(0, 2).join("/");
  return parts[0];
}

function groupBy(files) {
  const groups = new Map();
  for (const [file, info] of files) {
    const pkg = pkgOf(file);
    if (!groups.has(pkg)) groups.set(pkg, { valid: 0, covered: 0, files: [] });
    const g = groups.get(pkg);
    g.valid += info.valid;
    g.covered += info.covered;
    g.files.push([file, info]);
  }
  for (const g of groups.values()) {
    g.rate = g.valid === 0 ? 0 : g.covered / g.valid;
  }
  return groups;
}

function pct(x) {
  return (x * 100).toFixed(1) + "%";
}

function main() {
  if (!fs.existsSync(REPORT)) {
    log("no cobertura.xml yet — run: moon coverage analyze -- -f cobertura");
    process.exit(2);
  }
  const { total, files } = parseCobertura();
  const groups = groupBy(files);

  const lib = [...groups.values()].filter((g) => !g.files[0][0].startsWith("cmd/"));
  const cmd = [...groups.values()].filter((g) => g.files[0][0].startsWith("cmd/"));
  const sum = (gs) => ({
    valid: gs.reduce((a, g) => a + g.valid, 0),
    covered: gs.reduce((a, g) => a + g.covered, 0),
  });
  const libSum = sum(lib);
  const cmdSum = sum(cmd);

  log("line coverage");
  log("");
  log(`  whole module        ${total.covered}/${total.valid}  ${pct(total.rate)}`);
  log(`  libraries (src/)    ${libSum.covered}/${libSum.valid}  ${pct(libSum.valid ? libSum.covered / libSum.valid : 0)}`);
  log(`  binaries  (cmd/)    ${cmdSum.covered}/${cmdSum.valid}  ${pct(cmdSum.valid ? cmdSum.covered / cmdSum.valid : 0)}   (no in-process tests; cli-smoke.mjs drives these)`);
  log("");
  log("  by package");
  for (const g of [...groups.values()].sort((a, b) => a.rate - b.rate)) {
    const name = g.files[0][0].startsWith("cmd/") ? g.files[0][0].split("/").slice(0, 2).join("/") : g.files[0][0].split("/").slice(0, 2).join("/");
    log(`    ${name.padEnd(34)} ${String(g.covered).padStart(5)}/${String(g.valid).padEnd(5)} ${pct(g.rate).padStart(7)}`);
  }
  log("");
  log("  the ten least covered library files");
  const libFiles = [...files.entries()]
    .filter(([f]) => !f.startsWith("cmd/"))
    .sort((a, b) => a[1].rate - b[1].rate || b[1].valid - a[1].valid)
    .slice(0, 10);
  for (const [file, info] of libFiles) {
    log(`    ${file.padEnd(46)} ${String(info.covered).padStart(4)}/${String(info.valid).padEnd(4)} ${pct(info.rate).padStart(7)}`);
  }
  log("");
  log(`  report: ${path.relative(ROOT, REPORT)}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main();
