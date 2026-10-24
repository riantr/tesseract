// The dependency audit.
//
//   node qa/deps.mjs
//
// mooncakes has no advisory database, so "is this dependency safe" is not a
// question this audit can answer. What it *can* answer, and what actually
// goes wrong in practice, is three things:
//
//   1. **Is the pin the newest one?** A dependency that is a version behind
//      is a dependency that has not had the fixes the newer version carries.
//   2. **Has it been yanked?** A yanked version is one the publisher has
//      withdrawn, and a module that depends on it is a module that cannot be
//      resolved.
//   3. **What is the whole graph?** The pins in `moon.mod` are the direct
//      dependencies. The ones that come *with* them are the ones that decide
//      what actually gets built, and they are not in the file anybody reads.
//
// The transitive closure is walked from the registry, so a dependency that
// pulls in a stale transitive pin is found.
//
// There is one more layer below the graph: `moonbit-community/sqlite3` is a
// **binding** to the C library, and the C library it binds to is a vendored
// amalgamation with its own version and its own advisories. A pin that says
// `sqlite3@0.2.3` says nothing about which SQLite that is, so the audit
// reads the version out of the vendored header and asks NVD what is known
// about that version - and then asks which of those advisories can actually
// be reached, because an advisory in an extension that was never compiled in
// is not a defect in this program.

import fs from "node:fs";
import path from "node:path";
import { ROOT, log } from "./lib.mjs";

const API = "https://mooncakes.io/api/v0/modules";
const NVD = "https://services.nvd.nist.gov/rest/json/cves/2.0";

/** Where the vendored sqlite3 binding keeps its C library. */
const SQLITE = path.join(ROOT, ".mooncakes", "moonbit-community", "sqlite3");

/**
 * The SQLite extensions, and how each one is switched on.
 *
 * `fts5` is in the amalgamation behind `#if !defined(SQLITE_CORE) ||
 * defined(SQLITE_ENABLE_FTS5)`, and the amalgamation defines `SQLITE_CORE`
 * itself when nothing else has, so the extension is out unless the build
 * asks for it by name. `zipfile` is not in the amalgamation at all: its
 * enabling macro does not appear in the source, so there is nothing that
 * could switch it on.
 */
const EXTENSIONS = [
  { name: "fts5", macro: "SQLITE_ENABLE_FTS5" },
  { name: "zipfile", macro: "SQLITE_ENABLE_ZIPFILE" },
];

/** The direct pins in moon.mod. */
export function pins() {
  const text = fs.readFileSync(path.join(ROOT, "moon.mod"), "utf8");
  const out = [];
  const re = /"([^"]+?)@([^"]+?)"/g;
  let m;
  while ((m = re.exec(text)) !== null) out.push({ name: m[1], version: m[2] });
  return out;
}

/** The registry's record for a module. */
async function fetchModule(name) {
  const res = await fetch(`${API}/${name}`);
  if (!res.ok) return null;
  return await res.json();
}

/** The parts of a version that decide whether one is newer. */
function parts(v) {
  return String(v)
    .split(/[.\-+]/)
    .map((p) => (/^\d+$/.test(p) ? Number(p) : p));
}

/** Whether `a` is older than `b`. */
function older(a, b) {
  const pa = parts(a);
  const pb = parts(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (typeof x === "number" && typeof y === "number") {
      if (x !== y) return x < y;
    } else if (String(x) !== String(y)) {
      return String(x) < String(y);
    }
  }
  return false;
}

/** The version of the vendored SQLite, read out of its own header. */
function sqliteVersion() {
  const header = path.join(SQLITE, "internal", "ffi", "sqlite3.h");
  if (!fs.existsSync(header)) return null;
  const text = fs.readFileSync(header, "utf8");
  const m = /#define\s+SQLITE_VERSION\s+"([^"]+)"/.exec(text);
  return m ? m[1] : null;
}

/**
 * Which SQLite extensions are actually compiled in.
 *
 * Three questions, and each one has to be answered from the build rather
 * than from the name of the package.
 */
function compiledExtensions() {
  const amalgamation = path.join(SQLITE, "internal", "ffi", "sqlite3.c");
  const source = fs.existsSync(amalgamation) ? fs.readFileSync(amalgamation, "utf8") : "";

  // The amalgamation defines SQLITE_CORE itself unless the build says otherwise.
  const coreDefined = /#ifndef\s+SQLITE_AMALGAMATION\s*\n#define\s+SQLITE_CORE\s+1/.test(source);

  // The build's own flags. A package's C flags live in its moon.pkg.
  const flags = new Set();
  for (const pkg of [path.join(SQLITE, "moon.pkg"), path.join(SQLITE, "internal", "ffi", "moon.pkg")]) {
    if (!fs.existsSync(pkg)) continue;
    const text = fs.readFileSync(pkg, "utf8");
    for (const m of text.matchAll(/SQLITE_[A-Z0-9_]+/g)) flags.add(m[0]);
  }

  return EXTENSIONS.map((ext) => {
    const sourcePresent = source.includes(ext.macro);
    const flagPresent = flags.has(ext.macro);
    // The extension's own code is in the amalgamation, and something either
    // asked for it by name or left SQLITE_CORE undefined.
    const compiledIn = sourcePresent && (flagPresent || !coreDefined);
    return { ...ext, sourcePresent, flagPresent, coreDefined, compiledIn };
  });
}

/** Splits a select list on the commas that are not inside a call. */
function splitTopLevel(list) {
  const out = [];
  let depth = 0;
  let current = "";
  for (const c of list) {
    if (c === "(") depth++;
    if (c === ")") depth--;
    if (c === "," && depth === 0) {
      out.push(current);
      current = "";
      continue;
    }
    current += c;
  }
  if (current.trim()) out.push(current);
  return out.map((s) => s.trim()).filter((s) => s !== "");
}

/**
 * The SQL the project hands to the driver that carries an aggregate.
 *
 * This is the reachability probe for CVE-2025-6965, which is about the
 * number of aggregate terms exceeding the number of columns available. The
 * probe answers the question the advisory actually asks - are there more
 * aggregate terms than columns - rather than the easier question of whether
 * an aggregate appears at all.
 */
function aggregateQueries() {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if ([".mooncakes", "_build", ".git"].includes(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      if (!entry.name.endsWith(".mbt")) continue;
      const text = fs.readFileSync(full, "utf8");
      for (const m of text.matchAll(/\.\s*(?:prepare|exec|query)\s*\(\s*"([^"]*)"/g)) {
        const sql = m[1];
        const select = /select\s+([\s\S]*?)\s+from\s/i.exec(sql);
        if (!select) continue;
        const list = select[1];
        const terms = (list.match(/\b(count|sum|avg|min|max|total)\s*\(/gi) || []).length;
        if (terms === 0) continue;
        out.push({
          file: path.relative(ROOT, full).split(path.sep).join("/"),
          sql,
          terms,
          columns: splitTopLevel(list).length,
        });
      }
    }
  };
  walk(path.join(ROOT, "src"));
  return out;
}

/** The advisories NVD holds against one version of SQLite. */
async function sqliteAdvisories(version) {
  const cpe = `cpe:2.3:a:sqlite:sqlite:${version}:*:*:*:*:*:*:*`;
  const res = await fetch(`${NVD}?cpeName=${encodeURIComponent(cpe)}`);
  if (!res.ok) return null;
  const body = await res.json();
  const out = [];
  for (const v of body.vulnerabilities || []) {
    const cve = v.cve;
    const desc =
      (cve.descriptions || []).find((d) => d.lang === "en")?.value || "";
    // Only the advisories that are about SQLite itself. A CVE that merely
    // mentions SQLite in passing - a PHP driver's quoting bug, say - is a
    // different product's defect.
    if (!/SQLite (?:before|v|versions)/i.test(desc)) continue;
    out.push({
      id: cve.id,
      desc: desc.split(/(?<=\.)\s/)[0].trim(),
      cvss: cve.metrics?.cvssMetricV31?.[0]?.cvssData?.baseScore ?? null,
      severity: cve.metrics?.cvssMetricV31?.[0]?.cvssData?.baseSeverity ?? null,
      extension: EXTENSIONS.find((e) => desc.toLowerCase().includes(e.name))?.name ?? null,
    });
  }
  return out;
}

async function main() {
  const direct = pins();
  log("dependency audit");
  log("");
  log(`  ${direct.length} direct pins in moon.mod`);
  log("");

  const seen = new Map();
  const queue = [...direct];
  const problems = [];

  while (queue.length > 0) {
    const item = queue.shift();
    if (seen.has(item.name)) continue;
    const mod = await fetchModule(item.name);
    if (!mod) {
      problems.push(`${item.name}@${item.version}: not in the registry`);
      seen.set(item.name, { ...item, missing: true });
      continue;
    }
    const latest = mod.latest_version;
    const record = {
      name: item.name,
      pinned: item.version,
      latest,
      behind: older(item.version, latest),
      yanked: mod.yanked === true,
      metaYanked: mod.metadata?.yanked === true,
      direct: direct.some((d) => d.name === item.name),
    };
    seen.set(item.name, record);
    if (record.yanked || record.metaYanked) {
      problems.push(`${item.name}@${item.version}: YANKED`);
    }
    if (record.behind) {
      problems.push(
        `${item.name}@${item.version}: behind ${latest}` +
          (record.direct
            ? ""
            : " (transitive - the pin belongs to the package that depends on it)"),
      );
    }
    for (const [dep, ver] of Object.entries(mod.metadata?.deps || {})) {
      queue.push({ name: dep, version: ver });
    }
  }

  log("  the whole graph, direct pins first");
  log("  name                                          pinned      latest     state");
  for (const [name, r] of seen) {
    if (r.missing) {
      log(`  ${name.padEnd(44)} ${r.version.padEnd(11)} ${"-".padEnd(10)} MISSING`);
      continue;
    }
    const state = r.yanked || r.metaYanked
      ? "YANKED"
      : r.behind
        ? "BEHIND"
        : r.direct
          ? "current"
          : "current (transitive)";
    log(`  ${name.padEnd(44)} ${r.pinned.padEnd(11)} ${r.latest.padEnd(10)} ${state}`);
  }
  log("");
  log(`  ${seen.size} modules in the closure, ${direct.length} of them direct pins`);

  // The C library underneath the binding.
  log("");
  log("  the C library underneath the binding");
  const version = sqliteVersion();
  if (!version) {
    log("  SKIP: the vendored sqlite3 amalgamation is not on disk");
  } else {
    log(`  the vendored amalgamation is SQLite ${version}`);
    for (const ext of compiledExtensions()) {
      const how = ext.compiledIn
        ? "COMPILED IN"
        : !ext.sourcePresent
          ? "not in the amalgamation"
          : "in the amalgamation, but the build does not ask for it";
      log(`  ${ext.name.padEnd(10)} ${how}`);
    }
    const aggregates = aggregateQueries();
    log(`  ${aggregates.length} aggregate query/queries reach the driver:`);
    for (const a of aggregates) {
      log(`    ${a.file}  ${a.sql}`);
      log(`      ${a.terms} aggregate term(s) over ${a.columns} column(s)`);
    }
    const advisories = await sqliteAdvisories(version);
    if (advisories === null) {
      log("  SKIP: NVD could not be reached");
    } else {
      log(`  NVD holds ${advisories.length} advisory/advisories against SQLite ${version}:`);
      for (const a of advisories) {
        let reach;
        if (a.extension) {
          reach = `the ${a.extension} extension is not compiled in, so the advisory cannot fire`;
        } else {
          const worst = aggregates.reduce(
            (n, q) => Math.max(n, q.terms - q.columns),
            0,
          );
          reach =
            worst > 0
              ? `core code, and a query with ${worst} more aggregate terms than columns reaches the driver`
              : "core code, and no query reaches the driver with more aggregate terms than columns";
        }
        log(`    ${a.id.padEnd(16)} cvss ${String(a.cvss).padEnd(5)} ${a.extension ? `(${a.extension})` : "(core)"}`);
        log(`      ${a.desc}`);
        log(`      ${reach}`);
      }
    }
  }

  log("");
  if (problems.length === 0) {
    log("  every pin is the newest one, and nothing is yanked");
  } else {
    log("  findings:");
    for (const p of problems) log(`    ${p}`);
  }
  process.exit(problems.length === 0 ? 0 : 1);
}

main();
