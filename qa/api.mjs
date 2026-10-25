// The public-surface audit.
//
//   node qa/api.mjs
//
// A published package's public surface is not only a list of names: it is the
// set of promises a caller writes code against. This audit looks at the
// **local** source and reports five kinds of problem in that surface:
//
//   A1  naming      a public symbol whose name does not follow the convention
//                   the module itself uses. The convention is *learned* from the
//                   module — every package is measured against the shape its
//                   neighbours use — not imposed from outside.
//
//   A2  errors      a public function that returns a bare `String` error
//                   message while a sibling function in the same package
//                   returns a structured error. The caller cannot branch on
//                   one and not the other.
//
//   A3  invariants  a public struct whose fields are public, so a caller can
//                   set them, and whose entry point does not check them — even
//                   though the library refuses those values somewhere else.
//
//   A4  dead        a public symbol that is exported but never referenced
//                   anywhere else in the module, or referenced only by the
//                   module's own tests.
//
//   A5  waivers     a waiver that no longer matches anything in the module.
//
// A finding that is a **decision** rather than a defect can be waived, and a
// waiver is one item with the reason it rests on — not a blank switch. The
// waivers that matched are printed on every run, and A5 reports the ones that
// have gone stale, so a waiver cannot quietly outlive the thing it was
// written for.
//
// The counts per package come from the `pkg.generated.mbti` files, which are
// what `moon info` generates and therefore exactly what the registry sees.
//
// The exit code is non-zero when a finding is reported.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { ROOT, sourceFiles, log } from "./lib.mjs";

const findings = [];

/** The waivers that matched a finding on this run. */
const usedWaivers = new Set();

function finding(id, severity, what, where, why, observed) {
  findings.push({ id, severity, what, where, why, observed });
}

function rel(file) {
  return path.relative(ROOT, file).split(path.sep).join("/");
}

/* ------------------------------------------------------------------ *
 * Reading the public surface out of a `.mbti`
 * ------------------------------------------------------------------ */

/** The index of the `)` that closes the `(` at `open`. */
function matchParen(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** The index of the `}` that closes the `{` at `open`. */
function matchBrace(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * The public surface a `.mbti` describes.
 *
 * `values` are the public constants and free functions, `types` the public
 * types with their methods. A type with no `pub` is recorded separately,
 * because "declared" and "exposed" are different questions.
 */
function parseMbti(text) {
  const surface = {
    package: null,
    values: new Map(), // name -> { kind: "const" | "fn", ret, raises, params }
    types: new Map(), // name -> { public, methods: [], fields: [] }
    fns: [],
  };
  let inType = null;
  let inPublicType = false;

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("//") || line.startsWith("#")) continue;

    if (inType) {
      if (line.startsWith("}")) {
        // `} derive(Eq, @debug.Debug)` — the traits the compiler generated
        // the type's methods from.
        const derive = /derive\(([^)]*)\)/.exec(line);
        if (derive) surface.types.get(inType).derive = derive[1];
        inType = null;
        continue;
      }
      const field = /^([a-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/.exec(line);
      if (field && inPublicType) surface.types.get(inType).fields.push(field[1]);
      continue;
    }

    let m;
    if ((m = /^package\s+"([^"]+)"/.exec(line))) {
      surface.package = m[1];
      continue;
    }
    if ((m = /^pub\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/.exec(line))) {
      surface.values.set(m[1], {
        kind: "const",
        type: m[2].trim(),
        ret: m[2].trim(),
        params: [],
        raises: null,
      });
      continue;
    }
    if ((m = /^pub(\(all\))?\s+(struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      surface.types.set(m[3], { public: true, methods: [], fields: [] });
      inType = m[3];
      inPublicType = true;
      continue;
    }
    if ((m = /^(struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      surface.types.set(m[2], { public: false, methods: [], fields: [] });
      inType = m[2];
      inPublicType = false;
      continue;
    }
    if ((m = /^(pub\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      surface.types.set(m[2], {
        public: Boolean(m[1]),
        methods: [],
        fields: [],
      });
      continue;
    }
    if (line.startsWith("pub fn ") || line.startsWith("pub(all) fn ")) {
      const open = line.indexOf("(");
      if (open < 0) continue;
      const close = matchParen(line, open);
      if (close < 0) continue;
      const head = line.slice(line.indexOf("fn ") + 3, open).trim();
      const params = line.slice(open + 1, close).trim();
      const tail = line.slice(close + 1).trim();
      const arrow = tail.indexOf("->");
      let ret = null;
      let raises = null;
      if (arrow >= 0) {
        const after = tail.slice(arrow + 2).trim();
        // The interface file writes `raise` without the error type, so the
        // type is not always there to read.
        const raiseAt = after.search(/\s+raise\b/);
        if (raiseAt >= 0) {
          ret = after.slice(0, raiseAt).trim();
          raises = after.slice(raiseAt).replace(/^\s+raise\s*/, "").trim();
          if (!raises) raises = "(unspecified)";
        } else {
          ret = after;
        }
      }
      const owner = head.includes("::") ? head.split("::")[0] : null;
      const name = owner ? head.split("::")[1] : head;
      const record = { name, owner, params, ret, raises, head };
      surface.fns.push(record);
      if (owner) {
        const t = surface.types.get(owner);
        if (t) t.methods.push(name);
      } else {
        surface.values.set(name, {
          kind: "fn",
          ret,
          raises,
          params,
          paramsRaw: params,
        });
      }
    }
  }
  return surface;
}

/**
 * The native interface of a package that publishes no `.mbti`.
 *
 * `cmd/gui` is native-only, so `moon info` writes no interface for it under
 * the module's preferred (wasm) backend. `moon info --target native` prints
 * the native interface as a diff **without writing into the source tree**.
 */
function nativeSurface(pkgPath) {
  const relPath = pkgPath.replace("riantr/tesseract/", "");
  const r = spawnMoon(["info", "--target", "native", "--verbose", relPath]);
  const lines = r.split(/\r?\n/);
  const hunkAt = lines.findIndex((l) => l.startsWith("@@"));
  if (hunkAt < 0) return null;
  const body = [];
  for (let i = hunkAt + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith("#")) break;
    if (l.startsWith("+")) body.push(l.slice(1));
    else if (l.startsWith(" ")) body.push(l.slice(1));
  }
  if (body.length === 0) return null;
  const surface = parseMbti(body.join("\n"));
  surface.file = `(moon info --target native ${relPath})`;
  return surface;
}

function spawnMoon(args) {
  const r = spawnSync("moon", args, {
    cwd: ROOT,
    encoding: "utf8",
    shell: false,
    maxBuffer: 64 * 1024 * 1024,
  });
  return `${r.stdout || ""}${r.stderr || ""}`;
}

/* ------------------------------------------------------------------ *
 * Reading the source
 * ------------------------------------------------------------------ */

/**
 * The source with its comments and string literals removed.
 *
 * The counts below are about *code*, not about prose: a function name in a
 * doc comment is not a reference to it, and a word inside a string is not an
 * identifier. Stripping both is what makes the dead-surface count honest.
 */
function stripNoise(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (c === '"') {
      i++;
      while (i < text.length) {
        if (text[i] === "\\") {
          i += 2;
          continue;
        }
        if (text[i] === '"') {
          i++;
          break;
        }
        i++;
      }
      out += '""';
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** The line number of `index` in `text`. */
function lineOf(text, index) {
  return text.slice(0, index).split(/\r?\n/).length;
}

/**
 * The definition of the function `name` in `files`.
 *
 * `qualified` is the `Type::name` form when the function is a method. The
 * signature is returned as well as the body: the parameter *names* are what
 * say which value a function was handed, and the interface file only has
 * their types.
 */
function findFunction(files, name, qualified) {
  const patterns = qualified
    ? [
        new RegExp(`\\bfn\\s+${escapeRe(qualified)}\\s*\\(`),
        new RegExp(`\\bfn\\s+${escapeRe(name)}\\s*\\(`),
      ]
    : [new RegExp(`\\bfn\\s+${escapeRe(name)}\\s*\\(`)];
  for (const file of files) {
    const raw = fs.readFileSync(file, "utf8");
    const text = stripNoise(raw);
    for (const pattern of patterns) {
      const m = pattern.exec(text);
      if (!m) continue;
      const parenAt = text.indexOf("(", m.index);
      const parenEnd = matchParen(text, parenAt);
      if (parenEnd < 0) continue;
      const bodyStart = text.indexOf("{", parenEnd);
      if (bodyStart < 0) continue;
      const bodyEnd = matchBrace(text, bodyStart);
      if (bodyEnd < 0) continue;
      return {
        file,
        // The line number is read off the stripped text: stripping keeps the
        // newlines, so the line numbers are the same in both.
        line: lineOf(text, m.index),
        signature: text.slice(parenAt + 1, parenEnd),
        body: text.slice(bodyStart + 1, bodyEnd),
      };
    }
  }
  return null;
}

/** The `name : Type` pairs of a parameter list. */
function parseParams(signature) {
  const out = [];
  let depth = 0;
  let current = "";
  for (const c of signature) {
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth--;
    if (c === "," && depth === 0) {
      out.push(current);
      current = "";
      continue;
    }
    current += c;
  }
  if (current.trim()) out.push(current);
  return out
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const m = /^([a-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/.exec(p);
      if (m) return { name: m[1], type: m[2].trim() };
      return { name: p, type: p };
    });
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The packages the module's own source lives in. */
function packageOf(file) {
  const relPath = path.relative(ROOT, path.dirname(file)).split(path.sep).join("/");
  return relPath === "" ? "riantr/tesseract" : `riantr/tesseract/${relPath}`;
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */

function main() {
  /* --- the surfaces --------------------------------------------- */

  const surfaces = new Map();
  const addSurface = (pkgPath, surface, file) => {
    surface.file = file;
    surfaces.set(pkgPath, surface);
  };

  // The module root.
  const rootMbti = path.join(ROOT, "pkg.generated.mbti");
  if (fs.existsSync(rootMbti)) {
    addSurface(
      "riantr/tesseract",
      parseMbti(fs.readFileSync(rootMbti, "utf8")),
      "pkg.generated.mbti",
    );
  }

  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name === "pkg.generated.mbti") {
        const pkg = packageOf(full);
        addSurface(pkg, parseMbti(fs.readFileSync(full, "utf8")), rel(full));
      }
    }
  };
  walk(path.join(ROOT, "src"));
  walk(path.join(ROOT, "cmd"));

  // `cmd/gui` publishes no wasm interface — it is native-only — so its
  // native interface is read instead.
  for (const dir of [
    path.join(ROOT, "src"),
    path.join(ROOT, "cmd"),
  ]) {
    const listPackages = (d) => {
      for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const full = path.join(d, entry.name);
        const pkg = packageOf(full);
        if (!surfaces.has(pkg)) {
          const native = nativeSurface(pkg);
          if (native) surfaces.set(pkg, native);
        }
        listPackages(full);
      }
    };
    listPackages(dir);
  }

  /* --- the counts ----------------------------------------------- */

  log("public-surface audit");
  log("");
  log(
    `  ${"package".padEnd(38)} ${"types".padStart(6)} ${"fns".padStart(6)} ${"meth".padStart(6)} ${"const".padStart(6)}`,
  );
  const totals = { types: 0, fns: 0, methods: 0, consts: 0 };
  for (const pkg of [...surfaces.keys()].sort()) {
    const s = surfaces.get(pkg);
    const types = [...s.types.values()].filter((t) => t.public).length;
    const methods = s.fns.filter((f) => f.owner).length;
    const fns = s.fns.filter((f) => !f.owner).length;
    const consts = [...s.values.values()].filter((v) => v.kind === "const").length;
    totals.types += types;
    totals.fns += fns;
    totals.methods += methods;
    totals.consts += consts;
    log(
      `  ${pkg.replace("riantr/tesseract/", "").padEnd(38)} ${String(types).padStart(6)} ${String(
        fns,
      ).padStart(6)} ${String(methods).padStart(6)} ${String(consts).padStart(6)}`,
    );
  }
  log(
    `  ${"total".padEnd(38)} ${String(totals.types).padStart(6)} ${String(
      totals.fns,
    ).padStart(6)} ${String(totals.methods).padStart(6)} ${String(totals.consts).padStart(6)}`,
  );
  log("");

  /* --- A1: the naming convention -------------------------------- */

  auditNaming(surfaces);

  /* --- A2: the error vocabulary --------------------------------- */

  auditErrorStyles(surfaces);

  /* --- A3: the invariants --------------------------------------- */

  auditInvariants(surfaces);

  /* --- A4: the dead surface ------------------------------------- */

  auditDeadSurface(surfaces);

  /* --- the findings --------------------------------------------- */

  log("  findings");
  if (findings.length === 0) {
    log("    none");
  } else {
    for (const f of findings) {
      log(`  [${f.id}] (${f.severity}) ${f.what}`);
      log(`          where:    ${f.where}`);
      log(`          why:      ${f.why}`);
      log(`          observed: ${f.observed}`);
    }
  }
  log("");
  log("  the rules");
  const RULES = [
    ["A1.1", "a public name follows the convention the module learned"],
    ["A2.1", "a package does not mix a bare String error with a structured one"],
    ["A2.2", "a package does not report every failure as prose"],
    ["A3.1", "an entry point checks the public fields of what it stores"],
    ["A4.1", "a public symbol is referenced somewhere in the module"],
    ["A4.2", "a public symbol is used by the module, not only by its tests"],
    ["A5.1", "a waiver that no longer matches anything in the module"],
  ];
  for (const [id, what] of RULES) {
    const n = findings.filter((f) => f.id === id).length;
    log(`  ${id.padEnd(6)} ${String(n).padStart(3)}  ${what}`);
  }
  log("");
  log(`  ${findings.length} finding(s)`);
  process.exit(findings.length === 0 ? 0 : 1);
}

/* ------------------------------------------------------------------ *
 * A1 — the naming convention, learned from the module
 * ------------------------------------------------------------------ */

const SHAPES = {
  snake: /^[a-z][a-z0-9_]*$/,
  pascal: /^[A-Z][A-Za-z0-9]*$/,
  screaming: /^[A-Z][A-Z0-9_]*$/,
};

function auditNaming(surfaces) {
  // Every public name, by kind.
  const names = { fn: [], method: [], type: [], const: [] };
  for (const [pkg, s] of surfaces) {
    for (const [name, v] of s.values) {
      if (v.kind === "const") names.const.push({ name, pkg });
      else names.fn.push({ name, pkg });
    }
    for (const [name, t] of s.types) {
      if (t.public) names.type.push({ name, pkg });
    }
    for (const f of s.fns) {
      if (f.owner) names.method.push({ name: f.name, pkg, owner: f.owner });
    }
  }

  const learned = {};
  log("  the naming convention, learned from the module");
  for (const kind of ["fn", "method", "type", "const"]) {
    const tally = new Map();
    for (const entry of names[kind]) {
      for (const [shape, re] of Object.entries(SHAPES)) {
        if (re.test(entry.name)) tally.set(shape, (tally.get(shape) || 0) + 1);
      }
    }
    const sorted = [...tally.entries()].sort((a, b) => b[1] - a[1]);
    const total = names[kind].length;
    const [top, count] = sorted[0] || ["(none)", 0];
    const share = total === 0 ? 0 : count / total;
    learned[kind] = { shape: top, share };
    const runners = sorted
      .slice(1)
      .map(([shape, n]) => `${shape} ${n}`)
      .join(", ");
    log(
      `    ${kind.padEnd(7)} ${String(total).padStart(4)} names   ${top} ${count} (${(
        share * 100
      ).toFixed(1)}%)${runners ? `, also ${runners}` : ""}`,
    );
    if (total > 0 && share < 0.9) {
      finding(
        "A1.0",
        "LOW",
        `the module has no clear naming convention for ${kind} names`,
        "the module's own public surface",
        "with no dominant shape there is no convention to hold a name to.",
        `${top} ${count} of ${total}`,
      );
      continue;
    }
    const re = SHAPES[top];
    for (const entry of names[kind]) {
      if (re.test(entry.name)) continue;
      finding(
        "A1.1",
        "LOW",
        `a public ${kind} name does not follow the module's own ${top} convention: ${entry.name}`,
        surfaces.get(entry.pkg).file,
        `every other public ${kind} name in the module is ${top}; an outlier is a name a reader has to look up twice.`,
        `${entry.pkg}::${entry.name}`,
      );
    }
  }
  log("");
}

/* ------------------------------------------------------------------ *
 * A2 — the error vocabulary inside a package
 * ------------------------------------------------------------------ */

/** Splits `a, b` on the commas that are not inside brackets. */
function splitTopLevel(text) {
  const out = [];
  let depth = 0;
  let current = "";
  for (const c of text) {
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth--;
    if (c === "," && depth === 0) {
      out.push(current.trim());
      current = "";
      continue;
    }
    current += c;
  }
  if (current.trim()) out.push(current.trim());
  return out;
}

/** How a public function reports a failure. */
function errorStyle(fn, surface) {
  if (fn.raises) return "structured error type";
  const ret = fn.ret;
  if (!ret) return "none";
  const result = /^Result\[(.+)\]$/.exec(ret);
  if (result) {
    const parts = splitTopLevel(result[1]);
    const err = parts.length > 1 ? parts[parts.length - 1] : "";
    if (err === "String") return "bare string message";
    return "structured error type";
  }
  // A struct that carries an error code is a structured response.
  const t = surface.types.get(ret);
  if (t && t.fields.includes("error_code")) return "structured response";
  return "none";
}

function auditErrorStyles(surfaces) {
  log("  the error vocabulary of each package");
  for (const [pkg, s] of [...surfaces.entries()].sort()) {
    const styles = new Map();
    const examples = new Map();
    for (const fn of s.fns) {
      const style = errorStyle(fn, s);
      if (style === "none") continue;
      if (!styles.has(style)) styles.set(style, []);
      styles.get(style).push(fn);
      if (!examples.has(style)) examples.set(style, fn.head);
    }
    if (styles.size === 0) continue;
    const line = [...styles.entries()]
      .map(([style, fns]) => `${style} ${fns.length}`)
      .join(", ");
    log(`    ${pkg.replace("riantr/tesseract/", "").padEnd(26)} ${line}`);

    const bare = styles.get("bare string message") || [];
    const structured = [
      ...(styles.get("structured error type") || []),
      ...(styles.get("structured response") || []),
    ];
    const short = pkg.replace("riantr/tesseract/", "");
    const used = [];
    if (bare.length > 0 && structured.length > 0) {
      for (const fn of bare) {
        const waiver = waiverFor("A2.1", `${short}::${fn.head}`);
        if (waiver) {
          // The vocabulary of this package has been decided on purpose. The
          // decision is printed rather than silently applied.
          usedWaivers.add(waiver);
          used.push(waiver);
          continue;
        }
        finding(
          "A2.1",
          "MEDIUM",
          `a public function returns a bare String error while a sibling in the same package returns a structured error: ${fn.head}`,
          surfaces.get(pkg).file,
          "the caller has to match on prose for this call and on a value for the next one; only one of the two can be branched on.",
          `${pkg}: ${fn.head} -> ${fn.ret}`,
        );
      }
    } else if (bare.length > 0) {
      const waiver = waiverFor("A2.2", short);
      if (waiver) {
        usedWaivers.add(waiver);
        used.push(waiver);
      } else {
        finding(
          "A2.2",
          "LOW",
          `every failing public call in ${pkg} reports a bare String message`,
          surfaces.get(pkg).file,
          "a caller can compare the failure with another failure, but cannot branch on a machine-readable code; the prose is the whole contract.",
          `${bare.length} function(s), e.g. ${examples.get("bare string message")}`,
        );
      }
    }
    for (const w of used) {
      log(`      waived: ${w.symbol}`);
      log(`        ${w.why}`);
    }
  }
  log("");
}

/* ------------------------------------------------------------------ *
 * A3 — public fields, and whether the entry point checks them
 * ------------------------------------------------------------------ */

/** The type names a public function accepts as a parameter. */
function parameterTypes(fn) {
  if (!fn.params) return [];
  const out = [];
  for (const part of fn.params.split(",")) {
    const t = part.trim();
    if (!t) continue;
    if (/^(Self|[A-Z][A-Za-z0-9]*)\?$/.test(t)) out.push(t.replace("?", ""));
    else if (/^[A-Z][A-Za-z0-9]*$/.test(t)) out.push(t);
  }
  return out;
}

function auditInvariants(surfaces) {
  const sourceByPackage = new Map();
  for (const file of sourceFiles()) {
    const pkg = packageOf(file);
    if (!sourceByPackage.has(pkg)) sourceByPackage.set(pkg, []);
    sourceByPackage.get(pkg).push(file);
  }

  // Every field name in the module, and the struct it belongs to. An
  // assignment to a name in this set is an assignment into a struct.
  const fieldNames = new Set();
  for (const s of surfaces.values()) {
    for (const t of s.types.values()) {
      for (const f of t.fields) fieldNames.add(f);
    }
  }

  log("  public structs with public fields, and what checks them");
  for (const [pkg, s] of [...surfaces.entries()].sort()) {
    const files = sourceByPackage.get(pkg) || [];
    for (const [name, t] of s.types) {
      if (!t.public || t.fields.length === 0) continue;

      // A constructor the library offers for this struct that can **refuse**:
      // a function that returns the struct, or a `Result`/`Option` of it, and
      // whose body can say no. The fields such a constructor sets are fields
      // the library knows a correct value for — and, because the struct's
      // fields are public, fields a caller can set to something else.
      const constructors = s.fns.filter((f) => {
        const ret = f.ret || "";
        const returnsStruct =
          ret === name ||
          new RegExp(`^Result\\[${escapeRe(name)}\\b`).test(ret) ||
          new RegExp(`^${escapeRe(name)}\\?$`).test(ret);
        if (!returnsStruct) return false;
        const def = findFunction(files, f.name, f.owner ? `${f.owner}::${f.name}` : null);
        if (!def) return false;
        return /\bErr\s*\(/.test(def.body) || /\bNone\b/.test(def.body);
      });
      const constructorFields = new Set();
      for (const c of constructors) {
        const def = findFunction(files, c.name, c.owner ? `${c.owner}::${c.name}` : null);
        if (!def) continue;
        for (const field of t.fields) {
          const m = new RegExp(
            `^\\s*${escapeRe(field)}\\s*(?:,|:[^,\\n]+,)`,
            "m",
          ).exec(def.body);
          if (m) constructorFields.add(field);
        }
      }
      const guardName = constructors.length
        ? constructors.map((c) => c.head).join(", ")
        : null;

      // The public functions that take the struct by value. A method's
      // receiver is `Self`, not a supplied value, so it does not count.
      const takers = s.fns.filter((f) => parameterTypes(f).includes(name));
      const label = `${pkg.replace("riantr/tesseract/", "")}/${name}`;
      if (takers.length === 0) {
        log(
          `    ${label.padEnd(40)} ${String(t.fields.length).padStart(2)} field(s), constructor ${guardName || "none"}, no public function takes it`,
        );
        continue;
      }

      let supplied = 0;
      const unchecked = [];
      for (const fn of takers) {
        const def = findFunction(files, fn.name, fn.owner ? `${fn.owner}::${fn.name}` : null);
        if (!def) continue;
        const params = parseParams(def.signature);
        const given = params.filter((p) => p.type === name);
        if (given.length === 0) continue;

        // Does the function *put* the value somewhere, or only read it? A
        // function that reads a struct is a query; a function that stores one
        // is an entry point, and an entry point has to check what it stores.
        const stores = storesGiven(def.body, given, fieldNames);
        if (stores.length === 0) continue;
        supplied++;

        const validates = callsValidator(def.body, given);
        for (const field of t.fields) {
          if (new RegExp(`\\b${escapeRe(field)}\\b`).test(def.body)) continue;
          if (validates) continue;
          // Two kinds of evidence that the library knows a correct value for
          // this field: a constructor that computes it, and a refusal of the
          // field's value somewhere else in the package.
          const computedBy = constructorFields.has(field);
          const refusedAt = refusedElsewhere(files, field);
          if (!computedBy && !refusedAt) continue;
          unchecked.push({
            field,
            fn: fn.head,
            def,
            computedBy,
            refusedAt,
          });
        }
      }
      log(
        `    ${label.padEnd(40)} ${String(t.fields.length).padStart(2)} field(s), constructor ${guardName || "none"}, ${supplied} entry point(s)`,
      );
      for (const u of unchecked) {
        finding(
          "A3.1",
          "HIGH",
          `a public struct's field is public and the entry point that stores the struct never checks it: ${name}.${u.field} stored by ${u.fn}`,
          `${rel(u.def.file)}:${u.def.line}`,
          `the library refuses this field's value${
            u.refusedAt ? ` at ${u.refusedAt}` : ""
          }${
            u.computedBy
              ? `, and computes it itself in a constructor (${guardName})`
              : ""
          }, and the struct's fields are public, so a caller can set the field to a value the library would reject — the entry point does not look at it, so the bad value is stored and the failure surfaces later, somewhere else, as a different kind of failure.`,
          `${name}.${u.field} is unchecked in ${u.fn} (${rel(u.def.file)}:${u.def.line})${
            u.refusedAt ? `; refused at ${u.refusedAt}` : ""
          }${u.computedBy ? `; computed by ${guardName}` : ""}`,
        );
      }
    }
  }
  log("");
}

/** The assignments in `body` that put one of `given` into something else. */
function storesGiven(body, given, fieldNames) {
  const names = given.map((g) => g.name);
  const out = [];
  const re = /([A-Za-z_][A-Za-z0-9_\.\[\]]*)\s*[:=]\s*([^:=\n]*)/g;
  for (const m of body.matchAll(re)) {
    const target = m[1];
    const value = m[2];
    // A local declaration is not a store: `let total = ...` names a
    // variable, not a struct's field.
    const before = body.slice(Math.max(0, m.index - 8), m.index);
    if (/\b(let|mut|fn|for)\s+$/.test(before)) continue;
    if (!names.some((n) => new RegExp(`\\b${escapeRe(n)}\\b`).test(value))) {
      continue;
    }
    const intoAField =
      target.includes(".") ||
      target.includes("[") ||
      fieldNames.has(target);
    if (intoAField) out.push({ target, value: value.trim() });
  }
  return out;
}

/**
 * Where the library refuses this field's value.
 *
 * A comparison on the field that is followed closely by a refusal — an
 * `Err`, an `err_response`, a `raise` — is the library saying "that value is
 * not allowed". A field nobody ever compares is metadata, not an invariant.
 */
function refusedElsewhere(files, field) {
  const pattern = new RegExp(
    `\\b${escapeRe(field)}\\b\\s*(?:<|>|==|!=|>=|<=)\\s*("[^"]*"|\\d+L?|true|false|[A-Z][A-Z0-9_]*)`,
    "g",
  );
  for (const file of files) {
    const text = stripNoise(fs.readFileSync(file, "utf8"));
    for (const m of text.matchAll(pattern)) {
      const near = text.slice(m.index, m.index + 300);
      if (/\bErr\s*\(|\berr_response\s*\(|\braise\b/.test(near)) {
        return `${rel(file)}:${lineOf(text, m.index)}`;
      }
    }
  }
  return null;
}

/** Does the body call a validating helper on one of `given`? */
function callsValidator(body, given) {
  const names = given.map((g) => g.name);
  for (const n of names) {
    const re = new RegExp(
      `\\b([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\s*${escapeRe(n)}\\s*\\)`,
      "g",
    );
    for (const m of body.matchAll(re)) {
      if (/valid|usable|normal|check|saniti/i.test(m[1])) return m[1];
    }
    const re2 = new RegExp(
      `${escapeRe(n)}\\s*\\.\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\(`,
      "g",
    );
    for (const m of body.matchAll(re2)) {
      if (/valid|usable|normal|check|saniti/i.test(m[1])) return m[1];
    }
  }
  return null;
}

/* ------------------------------------------------------------------ *
 * A4 — the dead public surface
 * ------------------------------------------------------------------ */

/**
 * The public symbols the library deliberately does not call itself.
 *
 * A published package's surface is for its callers, and a symbol that only
 * the module's own tests reference is not a symbol the library forgot to
 * use — it is a symbol that is for somebody else. `Recency::is_active`
 * exists so a *caller* can say whether the policy is doing anything; the
 * store asks the policy for a weight and never asks whether it is on. That
 * is not the library failing to use its own API, it is the API being for a
 * consumer.
 *
 * Each entry says why, because a waiver whose reason stops being true is a
 * defect: the reason is the part that has to be read. A waiver that no
 * longer matches a finding is reported too — a stale waiver is a claim about
 * the code that the code has stopped supporting.
 */
const A4_WAIVERS = [
  {
    symbol: "src/tesseract::all_slabs",
    why: "the slabs of a lattice, for a caller that wants to group it; the library builds the one slab it needs through slab_through and never wants all of them at once",
  },
  {
    symbol: "src/tesseract::coord_filter",
    why: "a filter over the coordinates, which a caller hands to a query; the library's own queries name their coordinates directly",
  },
  {
    symbol: "src/tesseract::fixed_clock",
    why: "a frozen clock is a test and a reporting tool; the library stamps with the logical counter or with the host clock and never with a frozen one",
  },
  {
    symbol: "src/tesseract::line_key",
    why: "the name a caller gives a line it wants to talk about; the library names a line by the coordinates it shares",
  },
  {
    symbol: "src/tesseract::neighbours",
    why: "the cells next to a cell along one axis; the library's peer queries work on the cells that are occupied rather than on the ones that are adjacent",
  },
  {
    symbol: "src/tesseract::pad_left",
    why: "a consumer that renders a table pads its own columns; the library's own output is fixed-width and pads with pad_right",
  },
  {
    symbol: "src/tesseract::parse_error_message",
    why: "the prose a caller shows a person; the library carries the structured error, and this is its rendering",
  },
  {
    symbol: "src/tesseract::peer_count",
    why: "the number of lines through a lattice, for a status readout; the library's own queries count the peers they actually find",
  },
  {
    symbol: "src/tesseract::plane_through",
    why: "a plane is a grouping a caller asks for; the library's own sub-structures are lines and slabs",
  },
  {
    symbol: "src/tesseract::solve_lattice",
    why: "the closed-form solution, which a caller asks for as a whole; the library fills one cell at a time through the rule checks",
  },
  {
    symbol: "src/tesseract::TesseractLogger::clock_of",
    why: "which clock a logger stamps with is a question a report asks about a logger; the logger knows its own clock and never asks",
  },
  {
    symbol: "src/tesseract::TesseractLogger::log_debug",
    why: "debug is a level a caller chooses; the library logs its own outcomes at info and at error",
  },
  {
    symbol: "src/tesseract_dgp::cell_count",
    why: "the ceiling a caller sizes a dataset against; the library asks the lattice it is given and never needs the number",
  },
  {
    symbol: "src/tesseract_dgp::irm_dataset",
    why: "the IRM dataset is a caller's dataset; the library records whatever dataset it is handed",
  },
  {
    symbol: "src/tesseract_dgp::plr_dataset",
    why: "the PLR dataset is a caller's dataset; the library records whatever dataset it is handed",
  },
  {
    symbol: "src/tesseract_dgp::read_back",
    why: "reading a dataset back is a caller's check on what was recorded",
  },
  {
    symbol: "src/tesseract_dgp::record",
    why: "recording a dataset is a caller's action on a store the library hands out",
  },
  {
    symbol: "src/tesseract_dgp::to_sql",
    why: "the escape hatch for a caller who wants SQL rather than a recording",
  },
  {
    symbol: "src/tesseract_memory::filter_any",
    why: "a filter combinator, for a caller composing several conditions into one",
  },
  {
    symbol: "src/tesseract_memory::new_memory",
    why: "a convenience for a caller who wants a memory with a capacity and the host clock; the library's own tests need the clock to be a value, so they build it with new_memory_with_clock",
  },
  {
    symbol: "src/tesseract_memory::Memory::entries_of_kind",
    why: "retrieval by kind across every scope, which is a caller's query",
  },
  {
    symbol: "src/tesseract_memory::Memory::search_all_filtered_keys",
    why: "the keys of a store-wide filtered search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory::Memory::search_all_keys",
    why: "the keys of a store-wide search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory::Memory::search_filtered_keys",
    why: "the keys of a filtered search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory::Memory::search_keys",
    why: "the keys of a search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory::Metadata::with_kind",
    why: "a convenience for a caller adding the kind label to a set of labels",
  },
  {
    symbol: "src/tesseract_memory::Recency::is_active",
    why: "a predicate for a caller reporting on the policy; the store asks the policy for a weight and never asks whether it is on",
  },
  {
    symbol: "src/tesseract_memory::Scope::entries_of_kind",
    why: "retrieval by kind within one scope, which is a caller's query",
  },
  {
    symbol: "src/tesseract_memory::Scope::search_filtered_keys",
    why: "the keys of a scope's filtered search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory::Scope::search_keys",
    why: "the keys of a scope's search, for a caller that only wants to know what to read",
  },
  {
    symbol: "src/tesseract_memory_db::DurableMemory::reload",
    why: "re-reading the file is a caller's action; the store writes the file on its own schedule",
  },
];

/** The name a waiver list writes a symbol under. */
function symbolKey(pkg, owner, name) {
  const short = pkg.startsWith("riantr/tesseract/")
    ? pkg.slice("riantr/tesseract/".length)
    : pkg;
  return `${short}::${owner ? `${owner}::` : ""}${name}`;
}

/**
 * The error vocabulary this project has decided about.
 *
 * A rule that measures a **shape** cannot say whether the shape is the right
 * one — only that it is not the shape the rule prefers. The error vocabulary
 * of a package is a design decision, and this is the project's decision:
 *
 * - **A2.2** — a package whose every failure is prose is *uniform*, and
 *   uniform is the state the rule wants for mixing. The two packages below
 *   are uniform on purpose: every failure in them is either the file could
 *   not be read or the store refused the operation, and every caller shows
 *   that failure to a person. A machine-readable code would be read by
 *   nobody, and it would be a second vocabulary to keep in step with the
 *   first.
 *
 * - **A2.1** — the core package still reports some failures as prose and
 *   some as values: `lex` and `parse_statement` return their own enums, while
 *   the importers, the geometry and the resize return a `String`. That is a
 *   genuine inconsistency, and unifying it is a change to eight published
 *   signatures, their call sites, and the README's error table. It is
 *   planned as its own change rather than folded into the release that
 *   already breaks the surface for the opaque value types: one breaking
 *   change per release is legible, and two unrelated ones are not.
 *
 * Each entry says why, because a waiver whose reason stops being true is a
 * defect: the reason is the part that has to be read.
 */
const A2_WAIVERS = [
  {
    id: "A2.1",
    symbol: "src/tesseract::import_markdown",
    why: "the importers report prose and the parser reports values; unifying them is a change to eight published signatures and the README's error table, and is planned as its own release rather than folded into the one that already breaks the surface for the opaque value types",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::import_sql",
    why: "same decision as import_markdown: the prose is what every caller shows a person, and none of them branches on it",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::import_tsr",
    why: "same decision as import_markdown: the prose is what every caller shows a person, and none of them branches on it",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::json_path_parse",
    why: "same decision as import_markdown: a malformed path is a prose message for the person who wrote it",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::lattice_of",
    why: "same decision as import_markdown: the refusal names the side that was refused, which is the whole content of the failure",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::plane_through",
    why: "same decision as import_markdown: the refusal names the axis that was refused, which is the whole content of the failure",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract::Tesseract::set_side",
    why: "same decision as import_markdown: the refusal names the side that was refused and what it would have cost",
  },
  {
    id: "A2.1",
    symbol: "src/tesseract_sa::parse",
    why: "the scan parser reports prose and the rest of the package raises; the refusal is the analyzer's own message about a run that did not finish, and every caller shows it to a person",
  },
  {
    id: "A2.2",
    symbol: "src/tesseract_memory_db",
    why: "every failure in this package is either the file could not be read or the store refused the operation, and every caller shows it to a person; a machine-readable code would be read by nobody and would be a second vocabulary to keep in step with the prose",
  },
  {
    id: "A2.2",
    symbol: "src/tesseract_memory_index",
    why: "same decision as tesseract_memory_db: the index's failures are the file could not be read, or the index is out of step with the store, and both are shown to a person",
  },
];

/** Every waiver, of every rule. */
const ALL_WAIVERS = [...A4_WAIVERS, ...A2_WAIVERS];

/** The waiver that covers a finding, if one does. */
function waiverFor(id, key) {
  // The A4 list is all about A4.2, so it does not name the rule on each
  // entry; the A2 list does, because it covers two rules.
  return ALL_WAIVERS.find(
    (w) => (w.id || "A4.2") === id && w.symbol === key,
  );
}

function auditDeadSurface(surfaces) {
  const files = sourceFiles();
  const stripped = new Map();
  for (const file of files) {
    stripped.set(file, stripNoise(fs.readFileSync(file, "utf8")));
  }
  const isTest = (file) => file.endsWith("_test.mbt");
  let waived = 0;

  /** Where a name is referenced, outside its own definition. */
  const references = (name, owner) => {
    const out = [];
    const word = new RegExp(`\\b${escapeRe(name)}\\b`, "g");
    const qualified = owner
      ? new RegExp(`\\b${escapeRe(owner)}::${escapeRe(name)}\\b`, "g")
      : null;
    const call = new RegExp(`\\.${escapeRe(name)}\\s*\\(`, "g");
    for (const [file, text] of stripped) {
      const lines = text.split(/\r?\n/);
      lines.forEach((line, i) => {
        const hits = [...line.matchAll(word)].length;
        const qHits = qualified ? [...line.matchAll(qualified)].length : 0;
        const cHits = [...line.matchAll(call)].length;
        const total = qualified ? qHits + cHits : hits;
        if (total > 0) out.push({ file, line: i + 1, test: isTest(file) });
      });
    }
    return out;
  };

  /** The line a public symbol is defined on. */
  const definitionLine = (pkg, name, owner) => {
    const s = surfaces.get(pkg);
    if (!s) return null;
    const files = sourceFiles().filter((f) => packageOf(f) === pkg);
    const patterns = owner
      ? [new RegExp(`\\bfn\\s+${escapeRe(owner)}::${escapeRe(name)}\\s*\\(`)]
      : [
          new RegExp(`\\bfn\\s+${escapeRe(name)}\\s*\\(`),
          new RegExp(`\\bconst\\s+${escapeRe(name)}\\b`),
        ];
    for (const file of files) {
      const text = stripNoise(fs.readFileSync(file, "utf8"));
      for (const pattern of patterns) {
        const m = pattern.exec(text);
        if (m) return { file, line: lineOf(text, m.index) };
      }
    }
    return null;
  };

  log("  the dead public surface");
  let dead = 0;
  let testOnly = 0;
  let derivedCount = 0;
  for (const [pkg, s] of [...surfaces.entries()].sort()) {
    const symbols = [];
    for (const [name, v] of s.values) {
      symbols.push({ name, kind: v.kind === "const" ? "constant" : "function" });
    }
    for (const [name, t] of s.types) {
      if (t.public) symbols.push({ name, kind: "type" });
    }
    for (const f of s.fns) {
      if (!f.owner) continue;
      const owner = s.types.get(f.owner);
      const derived = owner && owner.derive ? derivedMethods(owner.derive) : [];
      if (derived.includes(f.name)) {
        derivedCount++;
        continue;
      }
      symbols.push({ name: f.name, kind: "method", owner: f.owner });
    }
    for (const sym of symbols) {
      const def = definitionLine(pkg, sym.name, sym.owner);
      let refs = references(sym.name, sym.owner);
      // The definition itself is not a reference.
      if (def) {
        refs = refs.filter((r) => !(r.file === def.file && r.line === def.line));
      }
      if (refs.length === 0) {
        dead++;
        const full = `${pkg}::${sym.owner ? `${sym.owner}::` : ""}${sym.name}`;
        finding(
          "A4.1",
          "LOW",
          `a public ${sym.kind} is exported but never referenced anywhere else in the module: ${sym.name}`,
          def ? `${rel(def.file)}:${def.line}` : surfaces.get(pkg).file,
          "a published package's surface is for its callers, so an unreferenced symbol is not automatically wrong — but nothing in the module holds it in place, so a change to it would break nobody here and break a consumer there.",
          full,
        );
      } else if (refs.every((r) => r.test)) {
        const full = `${pkg}::${sym.owner ? `${sym.owner}::` : ""}${sym.name}`;
        const waiver = waiverFor("A4.2", symbolKey(pkg, sym.owner, sym.name));
        if (waiver) {
          // A symbol the library deliberately does not call itself. The
          // finding is not raised; the waiver is printed instead, so the
          // decision is visible rather than silent.
          waived++;
          usedWaivers.add(waiver);
          continue;
        }
        testOnly++;
        finding(
          "A4.2",
          "LOW",
          `a public ${sym.kind} is referenced only by the module's own tests: ${sym.name}`,
          def ? `${rel(def.file)}:${def.line}` : surfaces.get(pkg).file,
          "the tests are the only thing holding it in place; the library itself does not use it.",
          `${full} (${refs.length} test reference(s))`,
        );
      }
    }
  }
  log(`    ${dead} symbol(s) with no reference in the module`);
  log(`    ${testOnly} symbol(s) referenced only by tests`);
  log(`    ${waived} symbol(s) referenced only by tests, and waived`);
  log(`    ${derivedCount} symbol(s) the compiler generated from a derive`);
  log("");

  log("  the waivers, and the reason each one rests on");
  if (usedWaivers.size === 0) {
    log("  none");
  }
  for (const w of usedWaivers) {
    log(`  ${w.symbol}`);
    log(`    ${w.why}`);
  }
  log("");

  // A waiver that no longer covers anything is a claim about the code that
  // the code has stopped supporting. It is a defect in the waiver list, not
  // a quiet leftover, so it is reported.
  for (const w of ALL_WAIVERS) {
    if (usedWaivers.has(w)) continue;
    finding(
      "A5.1",
      "LOW",
      `a waiver no longer matches anything in the module: ${w.id} ${w.symbol}`,
      "qa/api.mjs",
      "the waiver says this finding has been decided on purpose, and the finding is no longer in that position — either it has gone, or it has been fixed. A waiver that covers nothing is a claim about the code that the code has stopped supporting.",
      `${w.id} ${w.symbol}`,
    );
  }
}

/** The methods the compiler generates for a `derive(...)` clause. */
function derivedMethods(derive) {
  const out = [];
  if (/\bEq\b/.test(derive)) out.push("equal", "not_equal");
  if (/Debug/.test(derive)) out.push("to_repr");
  if (/\bHash\b/.test(derive)) out.push("hash");
  return out;
}

main();
