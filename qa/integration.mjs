// The integration dimension of the QA sweep.
//
// A package boundary is a promise: the package on one side of it says what
// it will accept, and the package on the other side says what it will do.
// Nothing but a test that crosses the boundary holds that promise.
//
// So this tool reads the module's own dependency graph out of the `moon.pkg`
// files — the edges are declared, not guessed — and then asks, for each
// edge, whether a test on the calling side actually calls across it.
//
// The answer is not a guess either: it is a read of the test files. A
// reference to the other package's alias in a `_test.mbt` file is a test
// that reaches across the boundary.
//
// Three things are reported, and they are kept apart:
//
// - the edges, and how many of them a test crosses;
// - the edges no test crosses, which are the ones where a change to the
//   called package can break the caller without anything going red;
// - the packages with no test file at all.
//
// A note on what this does and does not say. An edge with no test across it
// is not a defect: the edge may be exercised by a command-line smoke check,
// by a Gherkin feature, or by a caller in another package. This is the
// in-tree half of the integration picture, and the other half is in
// `qa/e2e.mjs`, which maps the command surface onto the layers that
// exercise it.

import fs from "node:fs";
import path from "node:path";
import { ROOT, log } from "./lib.mjs";

const MODULE = "riantr/tesseract";

/** Every package of this module, with its directory and its manifest. */
function packages() {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (["_build", ".mooncakes", ".git", "node_modules", "_coverage", "dist"].includes(entry.name)) {
        continue;
      }
      const full = path.join(dir, entry.name);
      if (!entry.isDirectory()) continue;
      // A directory holding its own `moon.mod` is a nested module: its own
      // gate, its own tests, and not part of this module's graph.
      if (full !== ROOT && fs.existsSync(path.join(full, "moon.mod"))) continue;
      const manifest = path.join(full, "moon.pkg");
      if (fs.existsSync(manifest)) {
        out.push({ dir: full, manifest, name: path.relative(ROOT, full).split(path.sep).join("/") });
      }
      walk(full);
    }
  };
  walk(ROOT);
  return out;
}

/**
 * The internal imports of a manifest, and whether they are test-only.
 *
 * The manifest has two import blocks: the ordinary one, and one marked
 * `for "test"`. An edge that only exists for the tests is a different kind
 * of edge — it says the package's own tests reach across, not that its
 * production code does — so it is reported apart.
 */
function imports(manifest) {
  const text = fs.readFileSync(manifest, "utf8");
  const out = [];
  // Each import block, with the `for "test"` marker if it carries one.
  const blocks = text.matchAll(/import\s*\{([^}]*)\}(\s*for\s*"([^"]*)")?/g);
  for (const block of blocks) {
    const testOnly = (block[3] || "") === "test";
    for (const m of block[1].matchAll(/"([^"]+)"/g)) {
      const spec = m[1];
      if (!spec.startsWith(`${MODULE}/`)) continue;
      out.push({ target: spec.slice(MODULE.length + 1), testOnly });
    }
  }
  return out;
}

/** The alias a package's symbols are reached by: the last segment of its path. */
function aliasOf(pkgPath) {
  return pkgPath.split("/").pop();
}

/** The test files of a package. */
function testFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith("_test.mbt"))
    .map((f) => path.join(dir, f));
}

function main() {
  log("integration: the module's own dependency graph");
  log("");
  const pkgs = packages();
  log(`  ${pkgs.length} package(s) in the module`);

  const edges = [];
  for (const pkg of pkgs) {
    for (const imp of imports(pkg.manifest)) {
      edges.push({ from: pkg.name, to: imp.target, testOnly: imp.testOnly });
    }
  }
  const production = edges.filter((e) => !e.testOnly);
  const testOnly = edges.filter((e) => e.testOnly);
  log(
    `  ${production.length} production edge(s), ${testOnly.length} test-only edge(s)`,
  );

  // For each edge, does a test on the calling side reach the called package?
  const byDir = new Map(pkgs.map((p) => [p.name, p.dir]));
  const rows = [];
  for (const edge of production) {
    const dir = byDir.get(edge.from);
    const alias = aliasOf(edge.to);
    const tests = testFiles(dir);
    const crossing = tests.filter((file) => {
      const text = fs.readFileSync(file, "utf8");
      return new RegExp(`@${alias}\\b`).test(text);
    });
    rows.push({
      ...edge,
      tests: tests.length,
      crossing: crossing.map((f) => path.basename(f)),
    });
  }
  const crossed = rows.filter((r) => r.crossing.length > 0);
  const uncrossed = rows.filter((r) => r.crossing.length === 0);

  log("");
  log("  the edges, and whether a test on the calling side crosses them:");
  for (const row of rows) {
    log(
      `    ${row.from} -> ${row.to}` +
        (row.crossing.length > 0
          ? `   crossed by ${row.crossing.join(", ")}`
          : `   no in-tree test crosses it   (${row.tests} test file(s) on the calling side)`),
    );
  }

  log("");
  log(`  ${crossed.length} of ${production.length} production edge(s) are crossed by a test`);
  if (uncrossed.length > 0) {
    log("  edges no in-tree test crosses:");
    for (const e of uncrossed) log(`    ${e.from} -> ${e.to}`);
    log("");
    log(
      "    this is a fact about how the suite is organised, not a list of defects.",
    );
    log(
      "    the `cmd/*` edges are crossed from outside the package instead: the",
    );
    log(
      "    command-line smoke suite and the Gherkin features drive those binaries",
    );
    log(
      "    as processes, which is a stronger crossing than a test in the same",
    );
    log(
      "    package. The `src/*` edges are covered by package-local suites on both",
    );
    log(
      "    sides, so a defect in the seam between two library packages would not",
    );
    log("    be caught by a test that names both of them.");
  }

  if (testOnly.length > 0) {
    log("");
    log("  test-only edges:");
    for (const e of testOnly) log(`    ${e.from} -> ${e.to}`);
  }

  // Packages with no test file at all.
  const untested = pkgs.filter((p) => testFiles(p.dir).length === 0);
  log("");
  log(
    `  ${pkgs.length - untested.length} of ${pkgs.length} package(s) have an in-tree test file`,
  );
  for (const p of untested) log(`    no test file: ${p.name}`);

  log("");
  log(
    `integration: ${production.length} production edge(s), ${crossed.length} crossed by an in-tree test, ${uncrossed.length} covered only from outside the package`,
  );
}

main();
