// The static audit.
//
//   node qa/sast.mjs
//
// The compiler is the first static analyser here: `moon check --deny-warn` on
// four targets is in the house gate, and it is the analyser that knows the
// language. What it does **not** know is the rules this project holds itself
// to - the ones that are about the *code* and not about the *types*.
//
// Three of the rules below are not plain text matches, because a text match
// cannot tell a real defect from a message that merely looks like one. A log
// line that begins with "INSERT: " is not a SQL statement, and a rule that
// flags it teaches you to ignore the rule.
//
//   sql-concat    A SQL statement reaches the driver as a constant or a bind
//                 parameter. No SQL text is assembled from a runtime value.
//
//                 The sink is the *driver* call - `prepare`, `exec`, `query` -
//                 and NOT the project's own `execute`, which runs the
//                 project's own SQL dialect over the lattice and never hands
//                 text to SQLite at all.
//
//   unwrap        An unwrap() outside a test is allowed when the code has
//                 already established that the value is there. There are two
//                 ways to establish it:
//
//                   - the compiler checked it: `x is Some(_)`, `x != None`
//                   - the code checked the bound that makes it so:
//                     `position_in_bounds(...)`, or a range test
//
//                 An unwrap with neither is a panic path, and a library that
//                 panics on its caller's input is a denial of service with
//                 extra steps.
//
//   ignore-result A Result is not dropped silently. The rule is scoped to the
//                 package the call is in, and to the functions that package
//                 declares as returning a Result. `put` is a Bool in one
//                 package and a Result in another, and a rule that cannot
//                 tell them apart flags both.
//
// A site that is established by a *library invariant* rather than by a local
// check is listed in WAIVERS below, with the invariant that establishes it.
// A waiver is not a silence: it is a claim, and it is printed on every run so
// that a reader can check it.

import fs from "node:fs";
import path from "node:path";
import { ROOT, sourceFiles, log } from "./lib.mjs";

/** The rules that are plain text matches. */
const RULES = [
  {
    id: "panic",
    what: "no panic() or abort() in library code",
    why: "the same reason as unwrap, and louder",
    test: /\b(?:panic|abort)\s*\(/,
    severity: "error",
    skipTests: true,
  },
  {
    id: "todo",
    what: "no TODO, FIXME or XXX left in the source",
    why: "a marker is a promise, and a promise nobody has to keep is a comment",
    test: /\b(TODO|FIXME|XXX|HACK)\b/,
    severity: "warn",
    skipTests: true,
  },
  {
    id: "secret",
    what: "no credential-shaped literal",
    why: "a token in the source is a token in everybody's history",
    test: /(?:api[_-]?key|secret|password|passwd|bearer|token)\s*[:=]\s*"[^"]{8,}"/i,
    severity: "error",
  },
  {
    id: "abs-path",
    what: "no absolute path is written into the source",
    why: "a path that works on one machine is a path that fails on another",
    test: /["'][A-Za-z]:\\{1,2}[^"']*["']/,
    severity: "warn",
    skipTests: true,
  },
];

/**
 * The sites that are established by an invariant rather than by a local check.
 *
 * Each one names the invariant. A waiver whose reason stops being true is a
 * defect, so the reason is the part that has to be read.
 *
 * Every reason here names the precondition it rests on. The lattice is the
 * one the library built — `lattice_of` refuses a side it cannot address, and
 * every consumer in this repository builds its lattice that way. A caller
 * that hand-builds a `Lattice` can break these invariants, because MoonBit's
 * `pub struct` exposes its fields; that gap is measured and reported by the
 * API audit (rule A3.1) rather than papered over here.
 */
const WAIVERS = [
  {
    file: "src/tesseract/db.mbt",
    needle: "coords: coords_of(lat, cell.position).unwrap(),",
    why: "a cell's position is validated by insert_stamped before it is stored, and the only writer of a cell (Tesseract::write_cell) is package-private, so a stored cell's position field always agrees with the slot it sits in",
  },
  {
    file: "src/tesseract/db.mbt",
    needle: "let c = coords_of(lat, cell.position).unwrap()",
    why: "same invariant as to_record: the cell came from the lattice's own slots",
  },
  {
    file: "src/tesseract/exec.mbt",
    needle: "coords: coords_of(lat, lat.first_position).unwrap(),",
    why: "the lattice is the one the library built: lattice_of refuses side < 1 and so sets first_position = 1 and total = side^4 >= 1, so the first position is inside the lattice. A caller that hand-builds a Lattice breaks this, which is the API audit's A3.1 finding",
  },
  {
    file: "cmd/main/main.mbt",
    needle: "let here = @tesseract.coords_of(lat, s.current_position).unwrap()",
    why: "set_position refuses an out-of-range position, the cyclic advance is current % total + 1, and a delete resets the cursor to first_position, so the cursor is always inside the lattice the library built",
  },
  {
    file: "cmd/persist/main.mbt",
    needle: "let here = @tesseract.coords_of(lat, s.current_position).unwrap()",
    why: "same cursor invariant as cmd/main",
  },
  {
    file: "src/tesseract/coords.mbt",
    needle: "Err(_) => abort(\"default_lattice: lattice_of(3) cannot fail\")",
    why: "lattice_of(3) cannot fail: its only refusals are side < 1 and side > MAX_SIDE, and 3 is neither",
  },
];

/** The driver calls that take SQL. */
const SQL_SINKS = /\.\s*(?:prepare|exec|query)\s*\(/g;

/** The words that make a comparison a bound check. */
const BOUND_WORDS = ["last_position", "first_position", "total"];

/** Every identifier in a piece of text. */
function identifiers(text) {
  return text.match(/[A-Za-z_][\w]*/g) || [];
}

/** The path of a file relative to the root, with forward slashes. */
function rel(file) {
  return path.relative(ROOT, file).split(path.sep).join("/");
}

/** The waiver that covers a line, if one does. */
function waiverFor(file, trimmed) {
  return WAIVERS.find((w) => w.file === file && w.needle === trimmed);
}

/**
 * The argument of a call whose open paren is at `open`.
 *
 * String literals are stepped over, so a paren inside a message does not
 * unbalance the scan.
 */
function argumentOf(text, open) {
  let depth = 0;
  let inString = false;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") {
        i++;
        continue;
      }
      if (c === '"') inString = false;
      continue;
    }
    if (c === '"') {
      inString = true;
      continue;
    }
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return text.slice(open + 1);
}

/**
 * What is being unwrapped: a plain path, or a call.
 *
 * `let r = checked.unwrap()` unwraps the path `checked`.
 * `let here = @tesseract.coords_of(lat, wanted).unwrap()` unwraps the *call*
 * `coords_of(lat, wanted)`, and the argument is what a bound check would
 * mention.
 */
function receiverOf(line, at) {
  let i = at - 1;
  while (i >= 0 && /\s/.test(line[i])) i--;
  const end = i + 1;
  if (i >= 0 && line[i] === ")") {
    let depth = 0;
    for (; i >= 0; i--) {
      if (line[i] === ")") depth++;
      else if (line[i] === "(") {
        depth--;
        if (depth === 0) break;
      }
    }
    const open = i;
    let j = open - 1;
    while (j >= 0 && /[\w.@]/.test(line[j])) j--;
    return {
      kind: "call",
      text: line.slice(j + 1, end),
      args: line.slice(open + 1, end - 1),
    };
  }
  let j = i;
  while (j >= 0 && /[\w.@]/.test(line[j])) j--;
  return { kind: "path", text: line.slice(j + 1, end) };
}

/** The line a function starts on, or -1 when there is none above. */
function functionStart(lines, line) {
  for (let i = line; i >= 0; i--) {
    if (/^\s*(?:pub\s+)?fn\s/.test(lines[i])) return i;
  }
  return -1;
}

/** The package a file belongs to: the nearest ancestor holding a moon.pkg. */
function packageOf(file) {
  let dir = path.dirname(file);
  for (;;) {
    if (fs.existsSync(path.join(dir, "moon.pkg"))) return dir;
    const up = path.dirname(dir);
    if (up === dir || !dir.startsWith(ROOT)) return ROOT;
    dir = up;
  }
}

/** The functions a package declares as returning a Result. */
function resultFunctions(files) {
  const names = new Set();
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const re = /\bfn\s+([A-Za-z_]\w*)\s*\([\s\S]{0,500}?\)\s*(?:raise\s+[A-Za-z_]\w*\s*)?->\s*Result\[/g;
    let m;
    while ((m = re.exec(text)) !== null) names.add(m[1]);
  }
  return names;
}

/**
 * What the file knows about its own SQL.
 *
 * The point is to answer one question - does any SQL text reach the driver
 * with a runtime value spliced into it - so the analysis is deliberately
 * small: a constant is fine, a binding is fine, and a concatenation is not.
 */
function sqlConcatenations(file, text, lines) {
  const findings = [];
  const constNames = new Set();
  const bindings = new Map();
  const params = new Map();
  const fnAt = [];

  // Where each line starts in the file. A match found in one line carries an
  // index into that line, and an index into that line is no use in a string
  // that is the whole file.
  const offsets = [];
  {
    const re = /[^\n]*(?:\n|$)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      offsets.push(m.index);
      if (m.index === re.lastIndex) re.lastIndex++;
    }
  }

  lines.forEach((line, i) => {
    let m = /\bconst\s+([A-Za-z_]\w*)\s*:/.exec(line);
    if (m) constNames.add(m[1]);
    m = /\blet\s+(?:mut\s+)?([A-Za-z_]\w*)\s*=\s*(.+)$/.exec(line);
    if (m) bindings.set(m[1], m[2]);
    m = /\bfn\s+([A-Za-z_][\w]*)\s*\(/.exec(line);
    if (m) {
      const open = text.indexOf("(", offsets[i] + m.index + m[0].length - 1);
      const list = argumentOf(text, open);
      const names = [];
      for (const p of list.split(",")) {
        const pm = /^\s*([A-Za-z_]\w*)\s*:/.exec(p);
        if (pm) names.push(pm[1]);
      }
      params.set(m[1], names);
      fnAt.push({ name: m[1], line: i });
    }
  });

  /** The function a line is inside, if any. */
  const enclosing = (line) => {
    let found = null;
    for (const f of fnAt) {
      if (f.line <= line) found = f.name;
      else break;
    }
    return found;
  };

  /** Whether an expression assembles a string out of pieces. */
  const assembles = (expr) => /"[^"]*"\s*\+|\+\s*"[^"]*"/.test(expr);

  for (const m of text.matchAll(SQL_SINKS)) {
    const open = m.index + m[0].length - 1;
    const arg = argumentOf(text, open).trim();
    const line = text.slice(0, m.index).split(/\r?\n/).length - 1;

    if (assembles(arg)) {
      findings.push({ line, text: lines[line] ? lines[line].trim() : arg, why: "the SQL text itself is assembled from pieces" });
      continue;
    }

    const idm = /^@?([A-Za-z_]\w*)$/.exec(arg);
    if (!idm) continue;
    const name = idm[1];

    if (bindings.has(name)) {
      const init = bindings.get(name);
      if (assembles(init)) {
        findings.push({ line, text: lines[line] ? lines[line].trim() : arg, why: `"${name}" is assembled from pieces and then handed to the driver` });
      }
      continue;
    }

    if (constNames.has(name)) continue;

    // A parameter: the question is what the callers pass to it.
    const fn = enclosing(line);
    if (!fn || !params.has(fn) || !params.get(fn).includes(name)) continue;
    const callRe = new RegExp("\\b" + fn.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\(", "g");
    for (const call of text.matchAll(callRe)) {
      const callOpen = call.index + call[0].length - 1;
      const callArg = argumentOf(text, callOpen);
      for (const piece of callArg.split(",")) {
        if (assembles(piece)) {
          findings.push({
            line,
            text: lines[line] ? lines[line].trim() : arg,
            why: `${fn} is called with SQL that is assembled from pieces`,
          });
        }
      }
    }
  }
  return findings;
}

/**
 * What every unwrap outside a test is standing on.
 *
 * The three shapes are "the compiler checked it", "the code checked the
 * bound", and "nothing checked it". Only the last one is a finding.
 */
function unwrapShapes(file, text, lines) {
  const findings = [];
  const waivers = [];
  const shapes = { guarded: 0, bounded: 0, waived: 0 };

  lines.forEach((line, i) => {
    const at = line.indexOf(".unwrap()");
    if (at < 0) return;
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) return;

    const waiver = waiverFor(rel(file), trimmed);
    if (waiver) {
      shapes.waived++;
      waivers.push(waiver);
      findings.push({ line: i, text: trimmed, severity: "waived", why: waiver.why });
      return;
    }

    const receiver = receiverOf(line, at);
    // The search is scoped to the function the unwrap is in. A check in a
    // different function says nothing about this value, and a check further
    // up the file than the function is not a check at all.
    const fnStart = functionStart(lines, i);
    const windowStart = fnStart >= 0 ? fnStart : Math.max(0, i - 8);

    // The compiler checked it.
    if (receiver.kind === "path") {
      const base = receiver.text.split(".").pop();
      for (let k = i - 1; k >= windowStart; k--) {
        const window = lines[k];
        const guarded =
          new RegExp("\\b" + base + "\\b[^\\n]*\\bis\\s+Some\\b").test(window) ||
          new RegExp("\\b" + base + "\\b[^\\n]*!=\\s*None\\b").test(window);
        if (guarded) {
          shapes.guarded++;
          findings.push({ line: i, text: trimmed, severity: "guarded", why: `${base} was checked above` });
          return;
        }
      }
    }

    // The code checked the bound.
    if (receiver.kind === "call") {
      const ids = identifiers(receiver.args);
      for (let k = i - 1; k >= windowStart; k--) {
        const window = lines[k];
        const hasBound = BOUND_WORDS.some((w) => window.includes(w));
        const hasCompare = /<=|<|>=|>/.test(window);
        const mentions = ids.some((id) => new RegExp("\\b" + id + "\\b").test(window));
        const checksInBounds = window.includes("position_in_bounds") && mentions;
        if (checksInBounds || (hasBound && hasCompare && mentions)) {
          shapes.bounded++;
          findings.push({ line: i, text: trimmed, severity: "bounded", why: `the bound was checked above (${window.trim().slice(0, 60)})` });
          return;
        }
      }
    }

    findings.push({ line: i, text: trimmed, severity: "unproven", why: "nothing above establishes that the value is there" });
  });

  return { findings, shapes, waivers };
}

/** An ignore() that drops a Result. */
function ignoredResults(file, lines, resultNames) {
  const findings = [];
  lines.forEach((line, i) => {
    const m = /\bignore\s*\(\s*(@?[A-Za-z_][\w.]*)\s*\(/.exec(line);
    if (!m) return;
    const name = m[1].split(".").pop();
    if (!resultNames.has(name)) return;
    findings.push({ line: i, text: line.trim() });
  });
  return findings;
}

function main() {
  const files = sourceFiles();
  const byPackage = new Map();
  for (const file of files) {
    const pkg = packageOf(file);
    if (!byPackage.has(pkg)) byPackage.set(pkg, []);
    byPackage.get(pkg).push(file);
  }
  const resultNames = new Map();
  for (const [pkg, pkgFiles] of byPackage) {
    resultNames.set(pkg, resultFunctions(pkgFiles));
  }

  const findings = [];
  const measures = new Map();
  const usedWaivers = new Set();
  const unwrapTotals = { guarded: 0, bounded: 0, waived: 0, unproven: 0 };

  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split(/\r?\n/);
    const isTest = /_test\.mbt$/.test(file);
    const pkg = rel(packageOf(file));

    // The plain text rules.
    lines.forEach((line, i) => {
      const trimmed = line.trim();
      if (trimmed.startsWith("//")) return;
      const waiver = waiverFor(rel(file), trimmed);
      for (const rule of RULES) {
        if (rule.skipTests && isTest) continue;
        if (!rule.test.test(line)) continue;
        if (waiver) {
          usedWaivers.add(waiver);
          continue;
        }
        findings.push({
          rule,
          file: rel(file),
          line: i + 1,
          text: trimmed.slice(0, 120),
        });
      }
    });

    // The SQL rule.
    for (const f of sqlConcatenations(file, text, lines)) {
      findings.push({
        rule: { id: "sql-concat", what: "no SQL text is assembled from a runtime value", severity: "error" },
        file: rel(file),
        line: f.line + 1,
        text: f.text.slice(0, 120),
        why: f.why,
      });
    }

    // The unwrap rule.
    if (!isTest) {
      const { findings: unwraps, shapes, waivers } = unwrapShapes(file, text, lines);
      for (const w of waivers) usedWaivers.add(w);
      for (const u of unwraps) {
        unwrapTotals.guarded += u.severity === "guarded" ? 1 : 0;
        unwrapTotals.bounded += u.severity === "bounded" ? 1 : 0;
        unwrapTotals.waived += u.severity === "waived" ? 1 : 0;
        unwrapTotals.unproven += u.severity === "unproven" ? 1 : 0;
        if (u.severity !== "unproven") continue;
        findings.push({
          rule: { id: "unwrap", what: "an unwrap is only allowed where the value is established", severity: "error" },
          file: rel(file),
          line: u.line + 1,
          text: u.text.slice(0, 120),
          why: u.why,
        });
      }
      const narrowings = lines.filter((l) => l.includes(".to_int()")).length;
      if (narrowings > 0) {
        measures.set(pkg, (measures.get(pkg) || 0) + narrowings);
      }
    }

    // The ignore rule.
    const pkgResultNames = resultNames.get(packageOf(file));
    if (!isTest) {
      for (const f of ignoredResults(file, lines, pkgResultNames)) {
        findings.push({
          rule: { id: "ignore-result", what: "a Result is not dropped silently", severity: "warn" },
          file: rel(file),
          line: f.line + 1,
          text: f.text.slice(0, 120),
        });
      }
    }
  }

  log("static audit");
  log("");
  log(`  ${files.length} source files in ${byPackage.size} packages`);
  log("");

  const errors = findings.filter((f) => f.rule.severity === "error");
  const warns = findings.filter((f) => f.rule.severity === "warn");
  for (const f of findings) {
    const mark = f.rule.severity === "error" ? "ERROR" : "warn ";
    log(`  ${mark}  ${f.rule.id.padEnd(14)} ${f.file}:${f.line}`);
    log(`          ${f.text}`);
    log(`          ${f.why || f.rule.what}`);
  }
  if (findings.length === 0) log("  nothing to report");
  log("");

  log("  the rules");
  for (const rule of RULES) {
    const n = findings.filter((f) => f.rule.id === rule.id).length;
    log(`  ${rule.id.padEnd(14)} ${String(n).padStart(3)}  ${rule.what}`);
  }
  const sqlN = findings.filter((f) => f.rule.id === "sql-concat").length;
  log(`  ${"sql-concat".padEnd(14)} ${String(sqlN).padStart(3)}  no SQL text is assembled from a runtime value`);
  const unwrapN = findings.filter((f) => f.rule.id === "unwrap").length;
  log(`  ${"unwrap".padEnd(14)} ${String(unwrapN).padStart(3)}  an unwrap is only allowed where the value is established`);
  log("");

  log("  where every unwrap outside a test is standing on");
  log(`  ${"guarded".padEnd(14)} ${String(unwrapTotals.guarded).padStart(3)}  the compiler checked it`);
  log(`  ${"bounded".padEnd(14)} ${String(unwrapTotals.bounded).padStart(3)}  the code checked the bound`);
  log(`  ${"waived".padEnd(14)} ${String(unwrapTotals.waived).padStart(3)}  established by a library invariant`);
  log(`  ${"unproven".padEnd(14)} ${String(unwrapTotals.unproven).padStart(3)}  nothing establishes it`);
  log("");

  log("  the measures");
  const narrowTotal = [...measures.values()].reduce((n, c) => n + c, 0);
  for (const [pkg, count] of [...measures.entries()].sort((a, b) => b[1] - a[1])) {
    log(`  ${pkg.padEnd(30)} ${String(count).padStart(4)}  narrowings from Int64 to Int`);
  }
  log(`  ${"total".padEnd(30)} ${String(narrowTotal).padStart(4)}  narrowings from Int64 to Int`);
  log("");

  log("  the waivers, and the invariant each one rests on");
  if (usedWaivers.size === 0) {
    log("  none");
  }
  for (const w of usedWaivers) {
    log(`  ${w.file}`);
    log(`    ${w.needle}`);
    log(`    ${w.why}`);
  }
  log("");

  log(`  ${errors.length} error(s), ${warns.length} warning(s)`);
  process.exit(errors.length === 0 ? 0 : 1);
}

main();
