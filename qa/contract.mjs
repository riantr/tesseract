// The contract dimension of the QA sweep.
//
// Three contracts are checked here, and each one is a promise the package
// makes to somebody who is not looking at this repository:
//
//   1. The **published surface** — what the registry's `module_index.json`
//      advertises for the published version, against what the local source
//      actually exposes. A package on mooncakes.io is a contract: if the
//      index advertises a symbol the source no longer has, a consumer's
//      code breaks at a version boundary nobody noticed. The version is the
//      one the probe module pins, so this audit and the probe always
//      measure the same artifact.
//   2. The **checkpoint format** — the durable memory's file format: its
//      constants, whether a file this build writes comes back out of this
//      build's reader, and what the reader does with a file whose header it
//      does not understand.
//   3. The **SQL error vocabulary** — the closed set of codes the core
//      library emits, and whether the test suite asserts on the codes rather
//      than only on the messages.
//
// Every number printed here was measured: read out of a file, fetched from
// the registry, or produced by running the probe in `qa/contract_probe/`.
// A check that could not be performed prints SKIP and says why — it never
// prints a PASS it did not earn.
//
// The exit code is non-zero when the **working tree** has a finding or a
// failed check. A finding about the **published** artifact — the version on
// the registry — is reported in full but does not fail the tree's audit: the
// tree is what the next release ships, and it is measured on its own. The
// two are kept apart on purpose, because "the audit is red" and "the
// published package is broken" are different claims.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { ROOT, log, scratch, cleanup } from "./lib.mjs";

const PROBE_DIR = path.join(ROOT, "qa", "contract_probe");

/**
 * The published version this audit measures.
 *
 * It is read out of the **probe module's own pin**, not written down here.
 * The probe and this audit have to measure the same artifact: if each
 * carried its own copy of the version, a release would bump one of them and
 * the audit would go on measuring the last release -- which is exactly what
 * happened at 0.1.14, where the probe had moved to the new version and the
 * audit's own copy had not.
 */
function readPublishedVersion() {
  try {
    const mod = fs.readFileSync(path.join(PROBE_DIR, "moon.mod"), "utf8");
    const m = /"riantr\/tesseract@([^"]+)"/.exec(mod);
    if (m) return m[1];
  } catch (e) {
    // Fall through: the version is reported as unknown rather than guessed.
  }
  return null;
}

const PUBLISHED_VERSION = readPublishedVersion();
const INDEX_URL =
  `https://assets.mooncakes.io/assets/riantr/tesseract@${PUBLISHED_VERSION}/module_index.json`;
const REGISTRY_URL = "https://mooncakes.io/api/v0/modules/riantr/tesseract";

/** The published package, as `moon` fetched it for the probe's dependency. */
const PUBLISHED_CACHE = path.join(
  PROBE_DIR,
  ".mooncakes",
  "riantr",
  "tesseract",
);

const findings = [];
let failed = false;

/**
 * A finding.
 *
 * `scope` says **what** the finding is about, and the two are not the same
 * thing:
 *
 * - `"tree"` (the default) — a defect in the **working tree**. This is what
 *   the next release will ship, so it fails the audit.
 * - `"published"` — a defect in the **published artifact**, i.e. in the
 *   version on the registry. The working tree may already have fixed it; the
 *   next release is what closes it. It is reported in full, because a
 *   consumer reading the registry today gets this code, but it does not
 *   fail the tree's audit.
 */
function finding(id, severity, what, where, why, observed, scope = "tree") {
  findings.push({ id, severity, what, where, why, observed, scope });
}

/** A finding about the published artifact rather than about the tree. */
function publishedFinding(id, severity, what, where, why, observed) {
  finding(id, severity, what, where, why, observed, "published");
}

/**
 * A finding about the **drift** between the tree and the registry.
 *
 * Drift is what a tree looks like between releases: the source has moved on
 * and the registry has not caught up yet. It is not a defect to fix in the
 * tree — it is what the next release reconciles — but it is printed in full,
 * because a symbol the registry advertises and the source no longer has
 * breaks a consumer at the version boundary, and that belongs in the release
 * notes.
 */
function driftFinding(id, severity, what, where, why, observed) {
  finding(id, severity, what, where, why, observed, "drift");
}

/** A difference between the tree and the registry, printed but not failed. */
function noteDrift(id, headline, detail) {
  log(`DRIFT [${id}] ${headline}`);
  if (detail) {
    for (const line of String(detail).split("\n")) log(`       ${line}`);
  }
}

/** A check that did not come out clean. */
function fail(id, headline, detail) {
  failed = true;
  log(`FAIL [${id}] ${headline}`);
  if (detail) {
    for (const line of String(detail).split("\n")) log(`       ${line}`);
  }
}

/**
 * A check against the **published artifact** that did not come out clean.
 *
 * It prints the same FAIL line as `fail`, so the defect is impossible to
 * miss, but it does not fail the tree's audit: the tree is measured
 * separately, and a defect that the tree has already fixed is not the tree's
 * defect.
 */
function failPublished(id, headline, detail) {
  log(`FAIL [${id}] (published ${PUBLISHED_VERSION}) ${headline}`);
  if (detail) {
    for (const line of String(detail).split("\n")) log(`       ${line}`);
  }
}

function pass(id, headline, detail) {
  log(`PASS [${id}] ${headline}`);
  if (detail) {
    for (const line of String(detail).split("\n")) log(`       ${line}`);
  }
}

function skip(id, headline, why) {
  log(`SKIP [${id}] ${headline}`);
  log(`       ${why}`);
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

/**
 * The public surface a `.mbti` describes.
 *
 * `values` are the public constants and free functions, `types` the public
 * types with their methods. A `type` with no `pub` is recorded separately,
 * because the difference between "declared" and "exposed" is exactly what the
 * published index turns on.
 */
function parseMbti(text) {
  const lines = text.split(/\r?\n/);
  const surface = {
    package: null,
    values: new Map(), // name -> { kind, type }
    types: new Map(), // name -> { public, methods: [], fields: [] }
    fns: [], // { name, owner, params, ret, raises }
  };
  let inType = null;
  let inPublicType = false;

  for (const raw of lines) {
    const line = raw.trim();
    if (line === "" || line.startsWith("//") || line.startsWith("#")) {
      if (line.startsWith("//")) continue;
      if (line.startsWith("#")) continue;
      continue;
    }
    if (inType) {
      if (line.startsWith("}")) {
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
      surface.values.set(m[1], { kind: "const", type: m[2].trim() });
      continue;
    }
    if ((m = /^pub(\(all\))?\s+(struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      const name = m[3];
      const isPublic = Boolean(m[1]) || line.startsWith("pub ");
      surface.types.set(name, { public: isPublic, methods: [], fields: [] });
      inType = name;
      inPublicType = isPublic;
      continue;
    }
    if ((m = /^(struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      surface.types.set(m[2], { public: false, methods: [], fields: [] });
      inType = m[2];
      inPublicType = false;
      continue;
    }
    // An opaque `type` declaration — `type Foo derive(ToJson)` — is a type
    // the package names but does not define. `cmd/gui` has twenty of them.
    if ((m = /^(pub\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line))) {
      surface.types.set(m[2], { public: Boolean(m[1]), methods: [], fields: [] });
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
        const raiseAt = after.indexOf(" raise ");
        if (raiseAt >= 0) {
          ret = after.slice(0, raiseAt).trim();
          raises = after.slice(raiseAt + 7).trim();
        } else {
          ret = after;
        }
      }
      const owner = head.includes("::") ? head.split("::")[0] : null;
      const name = head.includes("::") ? head.split("::")[1] : head;
      const record = { name, owner, params, ret, raises, head };
      surface.fns.push(record);
      if (owner) {
        const t = surface.types.get(owner);
        if (t) t.methods.push(name);
      } else {
        surface.values.set(name, { kind: "fn", type: ret, ret, raises });
      }
    }
  }
  return surface;
}

/** The packages that are executables, and so cannot be imported at all. */
function executablePackages(pkgPaths) {
  const out = new Set();
  for (const pkgPath of pkgPaths) {
    const rel = pkgPath.replace("riantr/tesseract/", "");
    const file =
      rel === "" ? path.join(ROOT, "moon.pkg") : path.join(ROOT, rel, "moon.pkg");
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, "utf8");
    if (/pkgtype\s*\(\s*kind\s*:\s*"executable"/.test(text)) out.add(pkgPath);
  }
  return out;
}

/** Every `.mbti` under `src/` and `cmd/`, as a map of package path -> surface. */
function localSurfaces() {
  const out = new Map();
  const add = (dir, pkgPath) => {
    const file = path.join(dir, "pkg.generated.mbti");
    if (!fs.existsSync(file)) return;
    const surface = parseMbti(fs.readFileSync(file, "utf8"));
    surface.file = path.relative(ROOT, file).split(path.sep).join("/");
    out.set(pkgPath, surface);
  };
  // The module root is a package too.
  add(ROOT, "riantr/tesseract");
  for (const base of ["src", "cmd"]) {
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.name === "pkg.generated.mbti") {
          const rel = path
            .relative(ROOT, path.dirname(full))
            .split(path.sep)
            .join("/");
          add(path.dirname(full), `riantr/tesseract/${rel}`);
        }
      }
    };
    walk(path.join(ROOT, base));
  }
  return out;
}

/**
 * The native interface of a package that publishes no `.mbti`.
 *
 * `cmd/gui` is `supported_targets = "native"` only, so `moon info` writes no
 * interface for it under the module's preferred (wasm) backend. The native
 * interface is still readable, and `moon info --target native` prints it as a
 * diff **without writing anything into the source tree** — which matters,
 * because the source tree belongs to somebody else.
 */
function nativeSurface(pkgPath) {
  const rel = pkgPath.replace("riantr/tesseract/", "");
  const r = spawnSync(
    "moon",
    ["info", "--target", "native", "--verbose", rel],
    { cwd: ROOT, encoding: "utf8", shell: false, maxBuffer: 64 * 1024 * 1024 },
  );
  const out = `${r.stdout || ""}${r.stderr || ""}`;
  const lines = out.split(/\r?\n/);
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
  surface.file = `(moon info --target native ${rel})`;
  return surface;
}

/* ------------------------------------------------------------------ *
 * Reading the published surface out of the registry index
 * ------------------------------------------------------------------ */

function flattenIndex(node, out) {
  if (node.package) {
    out.set(node.package.path, {
      values: node.package.values || [],
      types: (node.package.types || []).map((t) => ({
        name: t.name,
        methods: t.methods || [],
      })),
      typealias: node.package.typealias || [],
      traits: node.package.traits || [],
      errors: node.package.errors || [],
    });
  }
  for (const child of node.childs || []) flattenIndex(child, out);
}

/* ------------------------------------------------------------------ *
 * CHECK 1 — the published surface against the local surface
 * ------------------------------------------------------------------ */

async function checkPublishedSurface() {
  const ID = "C1";
  log("");
  log("=== CHECK 1: published surface vs local surface ===");

  if (!PUBLISHED_VERSION) {
    skip(
      ID,
      "published surface vs local surface",
      "the probe module pins no published version of riantr/tesseract, so there is nothing to measure",
    );
    return;
  }

  let index = null;
  try {
    const res = await fetch(INDEX_URL, {
      signal: AbortSignal.timeout(60000),
      headers: { accept: "application/json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
    index = await res.json();
  } catch (e) {
    skip(
      ID,
      "published surface vs local surface",
      `the registry index could not be fetched (${e.message}); ${INDEX_URL}`,
    );
    return;
  }

  const published = new Map();
  flattenIndex(index, published);

  const local = localSurfaces();
  const executables = executablePackages(published.keys());

  // `cmd/gui` publishes no wasm interface, so its native one is read instead.
  for (const pkgPath of published.keys()) {
    if (!local.has(pkgPath)) {
      const native = nativeSurface(pkgPath);
      if (native) local.set(pkgPath, native);
    }
  }

  let matchedValues = 0;
  let matchedTypes = 0;
  let matchedMethods = 0;
  const publishedOnly = [];
  const localOnly = [];
  const indexNotPublic = [];
  const declaredNotPublished = [];

  for (const [pkgPath, pub] of published) {
    const loc = local.get(pkgPath);
    if (!loc) {
      driftFinding(
        "C1.1",
        "HIGH",
        `the registry index advertises a package the local tree does not have: ${pkgPath}`,
        `${pkgPath}`,
        "a consumer that imports a package the source no longer has cannot build.",
        "the package is absent from src/ and cmd/",
      );
      continue;
    }

    const pubValues = new Set(pub.values);
    const locValues = new Set(loc.values.keys());
    for (const name of pubValues) {
      if (locValues.has(name)) matchedValues++;
      else publishedOnly.push(`${pkgPath}::${name} (value)`);
    }
    for (const name of locValues) {
      if (!pubValues.has(name)) localOnly.push(`${pkgPath}::${name} (value)`);
    }

    const pubTypes = new Map(pub.types.map((t) => [t.name, t.methods]));
    const locPublicTypes = new Map(
      [...loc.types.entries()]
        .filter(([, t]) => t.public)
        .map(([n, t]) => [n, t.methods]),
    );
    const locAllTypes = new Set(loc.types.keys());

    for (const [name, methods] of pubTypes) {
      if (!locPublicTypes.has(name)) {
        indexNotPublic.push(
          `${pkgPath}::${name}` +
            (locAllTypes.has(name) ? " (declared but not public)" : " (not declared)"),
        );
        continue;
      }
      matchedTypes++;
      const locMethods = new Set(locPublicTypes.get(name));
      for (const m of methods) {
        if (locMethods.has(m)) matchedMethods++;
        else publishedOnly.push(`${pkgPath}::${name}::${m} (method)`);
      }
      for (const m of locMethods) {
        if (!methods.includes(m)) localOnly.push(`${pkgPath}::${name}::${m} (method)`);
      }
    }
    for (const name of locPublicTypes.keys()) {
      if (!pubTypes.has(name)) localOnly.push(`${pkgPath}::${name} (type)`);
    }
    for (const name of locAllTypes) {
      if (!pubTypes.has(name)) declaredNotPublished.push(`${pkgPath}::${name}`);
    }
  }

  log(
    `     packages in index: ${published.size}; packages in local tree: ${local.size}`,
  );
  log(
    `     symbols matched: ${matchedValues} values, ${matchedTypes} types, ${matchedMethods} methods`,
  );
  log(`     published but not in the local public surface: ${publishedOnly.length}`);
  log(`     local public surface but not published: ${localOnly.length}`);

  if (publishedOnly.length > 0) {
    for (const item of publishedOnly) {
      driftFinding(
        "C1.2",
        "HIGH",
        `the published index advertises a symbol the local source does not expose: ${item}`,
        "registry module_index.json vs the local pkg.generated.mbti",
        "a consumer that trusts the index writes code against a symbol that is not there, and the build breaks at the consumer, not at the publisher.",
        item,
      );
    }
    noteDrift(
      ID,
      `published surface vs local surface: ${publishedOnly.length} symbol(s) published but missing locally`,
      publishedOnly.join("\n"),
    );
  } else if (localOnly.length > 0) {
    for (const item of localOnly) {
      driftFinding(
        "C1.3",
        "MEDIUM",
        `the local public surface has a symbol the published index does not advertise: ${item}`,
        "the local pkg.generated.mbti vs registry module_index.json",
        "the source and the registry disagree about the package's surface; a consumer reading the index cannot find a symbol that does exist.",
        item,
      );
    }
    noteDrift(
      ID,
      `published surface vs local surface: ${localOnly.length} symbol(s) local but not published`,
      localOnly.join("\n"),
    );
  } else {
    pass(
      ID,
      `published surface vs local surface: ${matchedValues + matchedTypes + matchedMethods} symbols matched, 0 mismatched`,
    );
  }

  // The index also names types the package declares but does not expose.
  if (indexNotPublic.length > 0) {
    log(
      `     index names ${indexNotPublic.length} type(s) the package does not expose publicly`,
    );
    const byPackage = new Map();
    for (const item of indexNotPublic) {
      const pkg = item.split("::")[0];
      if (!byPackage.has(pkg)) byPackage.set(pkg, []);
      byPackage.get(pkg).push(item.split("::").slice(1).join("::"));
    }
    for (const [pkg, names] of byPackage) {
      const executable = executables.has(pkg);
      publishedFinding(
        "C1.4",
        executable ? "LOW" : "MEDIUM",
        `the published index names ${names.length} type(s) the package does not expose publicly: ${pkg}`,
        "registry module_index.json",
        executable
          ? "the index lists type names no consumer can reach — the package is an executable, so it cannot be imported at all, and the types in it are private; a tool that generates code or documentation from the index produces references that do not resolve."
          : "the index lists type names a consumer cannot name in code; a consumer that reads the index and writes the import gets a compile error rather than a missing feature.",
        names.join(", "),
      );
    }
  }

  // The published package's own interface files, byte for byte.
  if (fs.existsSync(PUBLISHED_CACHE)) {
    let same = 0;
    const differing = [];
    const walk = (dir, rel) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        const r = rel ? `${rel}/${entry.name}` : entry.name;
        if (entry.isDirectory()) walk(full, r);
        else if (entry.name === "pkg.generated.mbti") {
          const localFile = path.join(ROOT, r);
          if (!fs.existsSync(localFile)) {
            differing.push(`${r} (absent locally)`);
            continue;
          }
          const a = fs.readFileSync(localFile, "utf8");
          const b = fs.readFileSync(full, "utf8");
          if (a === b) same++;
          else differing.push(r);
        }
      }
    };
    walk(PUBLISHED_CACHE, "");
    log(
      `     published package's own interface files: ${same} identical, ${differing.length} differing`,
    );
    if (differing.length > 0) {
      for (const d of differing) {
        driftFinding(
          "C1.5",
          "HIGH",
          `the published package's interface file differs from the local one: ${d}`,
          d,
          "the package on mooncakes.io does not carry the public surface the working tree has.",
          d,
        );
      }
      noteDrift(
        ID,
        "published package bytes differ from the local tree",
        differing.join("\n"),
      );
    } else {
      log(`       every published pkg.generated.mbti is byte-identical to the local one`);
    }
  } else {
    skip(
      "C1.6",
      "published package bytes",
      `the published package is not in the probe's dependency cache (${PUBLISHED_CACHE})`,
    );
  }

  // The registry record, for completeness: is this the version it says it is?
  try {
    const res = await fetch(REGISTRY_URL, {
      signal: AbortSignal.timeout(60000),
      headers: { accept: "application/json" },
    });
    if (res.ok) {
      const rec = await res.json();
      log(
        `     registry: latest_version=${rec.latest_version} yanked=${rec.yanked}`,
      );
      if (rec.latest_version !== PUBLISHED_VERSION) {
        publishedFinding(
          "C1.7",
          "MEDIUM",
          `the registry's latest version is ${rec.latest_version}, not the ${PUBLISHED_VERSION} this check reads`,
          REGISTRY_URL,
          "the check compares against a version that is no longer the newest one.",
          `latest_version=${rec.latest_version}`,
        );
      }
    }
  } catch (e) {
    log(`     registry record: SKIP (${e.message})`);
  }
}

/* ------------------------------------------------------------------ *
 * CHECK 2 — the checkpoint format contract
 * ------------------------------------------------------------------ */

function readFormatConstants() {
  const src = path.join(
    ROOT,
    "src",
    "tesseract_memory_db",
    "format.mbt",
  );
  const text = fs.readFileSync(src, "utf8");
  const version = /pub\s+const\s+FORMAT_VERSION\s*:\s*Int64\s*=\s*(-?\d+)L?/.exec(
    text,
  );
  const key = /pub\s+const\s+HEADER_KEY\s*:\s*String\s*=\s*"([^"]*)"/.exec(text);
  return {
    file: path.relative(ROOT, src).split(path.sep).join("/"),
    version: version ? Number(version[1]) : null,
    versionRaw: version ? version[1] : null,
    key: key ? key[1] : null,
  };
}

/** The `PROBE <name> <value>` lines the probe printed. */
function parseProbeOutput(text) {
  const facts = new Map();
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*PROBE\s+(\S+)\s*(.*)$/.exec(line);
    if (m) facts.set(m[1], m[2].trim());
  }
  return facts;
}

function checkCheckpointFormat() {
  const ID = "C2";
  log("");
  log("=== CHECK 2: checkpoint format contract ===");
  if (!PUBLISHED_VERSION) {
    skip(
      ID,
      "checkpoint format contract",
      "the probe module pins no published version of riantr/tesseract, so there is nothing to measure",
    );
    return;
  }
  log(
    `     measured against the PUBLISHED artifact riantr/tesseract@${PUBLISHED_VERSION}`,
  );
  log(
    "     (the working tree is measured separately, in CHECK 2b — a nested module cannot reach the tree by path, so the tree's own refusal is proved by its own tests)",
  );

  const constants = readFormatConstants();
  log(
    `     FORMAT_VERSION = ${constants.version}   HEADER_KEY = "${constants.key}"`,
  );
  log(`     source: ${constants.file}`);

  if (constants.version === null || constants.key === null) {
    skip(ID, "checkpoint format contract", "the format constants could not be read");
    return;
  }

  const keyBytes = Buffer.from(constants.key, "utf8");
  const keyHex = [...keyBytes].map((b) => b.toString(16).padStart(2, "0")).join(" ");
  log(`     HEADER_KEY bytes (utf-8): ${keyHex}`);

  const dir = scratch("contract");
  let r;
  try {
    r = spawnSync("moon", ["-C", PROBE_DIR, "test"], {
      cwd: ROOT,
      encoding: "utf8",
      shell: false,
      maxBuffer: 64 * 1024 * 1024,
      timeout: 300000,
      env: { ...process.env, TESSERACT_PROBE_DIR: dir },
    });
  } finally {
    // The files are read below, so the directory is removed at the end of the
    // check rather than here.
  }

  const out = `${r.stdout || ""}${r.stderr || ""}`;
  const facts = parseProbeOutput(out);
  if (facts.size === 0) {
    skip(
      ID,
      "checkpoint format contract",
      `the probe produced no facts (exit ${r.status}); it did not run`,
    );
    cleanup(dir);
    return;
  }

  const summary = /Total tests:\s*(\d+),\s*passed:\s*(\d+),\s*failed:\s*(\d+)/.exec(
    out,
  );
  if (summary) {
    log(
      `     probe: ${summary[1]} tests, ${summary[2]} passed, ${summary[3]} failed`,
    );
  }

  // The file's own magic bytes, read out of the file the probe wrote.
  const checkpoint = facts.get("roundtrip_path");
  if (checkpoint && fs.existsSync(checkpoint)) {
    const head = fs.readFileSync(checkpoint).subarray(0, 16);
    const hex = [...head].map((b) => b.toString(16).padStart(2, "0")).join(" ");
    log(`     checkpoint file magic (first 16 bytes): ${hex}`);
    log(`     checkpoint file magic (ascii): ${JSON.stringify(head.toString("latin1"))}`);
    if (head.toString("latin1") !== "SQLite format 3\0") {
      publishedFinding(
        "C2.1",
        "HIGH",
        "the checkpoint file is not the format this check expected",
        checkpoint,
        "a consumer that has to read a checkpoint written by another build needs to know the file's magic.",
        `first 16 bytes: ${hex}`,
      );
    }
  } else {
    log("     checkpoint file magic: SKIP (the probe wrote no file to read)");
  }

  const headerValue = facts.get("header_value");
  if (headerValue) log(`     header cell value: ${headerValue}`);
  const headerKey = facts.get("header_row_key");
  if (headerKey) log(`     header cell key: ${headerKey}`);

  // (a) The round trip.
  const roundtripOk =
    facts.get("roundtrip_open") === "ok" &&
    facts.get("roundtrip_entries") === "2" &&
    facts.get("roundtrip_alpha") === "1" &&
    facts.get("roundtrip_beta") === "2";
  if (roundtripOk) {
    pass(
      "C2.2",
      "a checkpoint written by this build is read back by this build",
      `entries=${facts.get("roundtrip_entries")} alpha=${facts.get(
        "roundtrip_alpha",
      )} beta=${facts.get("roundtrip_beta")} clock=${facts.get(
        "roundtrip_clock",
      )} now=${facts.get("roundtrip_now")}`,
    );
  } else {
    failPublished(
      "C2.2",
      "a checkpoint written by this build is not read back by this build",
      `open=${facts.get("roundtrip_open")} entries=${facts.get(
        "roundtrip_entries",
      )} alpha=${facts.get("roundtrip_alpha")} beta=${facts.get("roundtrip_beta")}`,
    );
  }

  // (b) What the reader does with a file it does not understand.
  const refusals = [
    {
      id: "C2.3",
      probe: "bad_version",
      title: "a checkpoint whose format version this build does not know",
      refused: () => facts.get("bad_version_open") === "err",
      describe: () =>
        `open=${facts.get("bad_version_open")} entries=${facts.get(
          "bad_version_entries",
        )} clock=${facts.get("bad_version_clock")}`,
      contract:
        "src/tesseract_memory_db/format.mbt:31-33 — \"A checkpoint that carries a version this build does not know is refused rather than half-read\"",
      why: "a store that half-reads a file it does not understand is worse than one that says it cannot read the file, and the file says it refuses.",
    },
    {
      id: "C2.4",
      probe: "bad_key",
      title: "a file whose header cell key is not this format's",
      refused: () => facts.get("bad_key_open") === "err",
      describe: () =>
        `open=${facts.get("bad_key_open")} entries=${facts.get(
          "bad_key_entries",
        )} header_row_key=${facts.get("bad_key_header_row_key")}`,
      contract:
        "src/tesseract_memory_db/store.mbt:767-779 — the header key is the file's identity",
      why: "a file that is not a tesseract-memory checkpoint is accepted as one, so a caller cannot tell what it opened.",
    },
    {
      id: "C2.5",
      probe: "no_header",
      title: "a checkpoint with no header cell at all",
      refused: () => facts.get("no_header_open") === "err",
      describe: () =>
        `open=${facts.get("no_header_open")} entries=${facts.get(
          "no_header_entries",
        )}`,
      contract:
        "src/tesseract_memory_db/format.mbt:31-33 — the same refusal",
      why: "a file with no header is not a checkpoint, and is read as one.",
    },
    {
      id: "C2.6",
      probe: "reload",
      title: "a reload of a checkpoint with an unknown version",
      // The refusal may land at the open or at the reload, and refusing
      // earlier is the stronger answer: a build that will not open the file
      // cannot reload it either. What the contract forbids is the file being
      // read, not the step that notices it.
      refused: () =>
        facts.has("reload_err") || facts.get("reload_open") === "err",
      describe: () =>
        `reload=${facts.has("reload_err") ? "refused" : "accepted"} entries=${facts.get(
          "reload_entries",
        )} store_had=${facts.get("reload_before")} store_kept=${facts.get(
          "reload_after",
        )}`,
      contract:
        "src/tesseract_memory_db/store.mbt:186-198 — reload replaces what the store holds with what the file holds",
      why: "a reload is the operation that empties a store, so a file the reader does not understand empties it as well.",
    },
  ];

  for (const r of refusals) {
    const refused = r.refused();
    if (refused) {
      pass(
        r.id,
        `${r.title} is refused`,
        facts.get(`${r.probe}_message`) || "",
      );
    } else {
      const observed = r.describe
        ? r.describe()
        : `open=${facts.get(`${r.probe}_open`)}`;
      failPublished(
        r.id,
        `${r.title} is NOT refused — it is read`,
        observed,
      );
      publishedFinding(
        r.id,
        "HIGH",
        `${r.title} is read instead of refused`,
        r.contract,
        r.why,
        observed,
      );
    }
  }

  // (c) A file that is not a database at all: the one refusal that works.
  if (facts.get("garbage_open") === "err") {
    pass(
      "C2.7",
      "a file that is not a checkpoint at all is refused",
      facts.get("garbage_message") || "",
    );
  } else {
    failPublished(
      "C2.7",
      "a file that is not a checkpoint at all is NOT refused",
      `open=${facts.get("garbage_open")} entries=${facts.get("garbage_entries")}`,
    );
    publishedFinding(
      "C2.7",
      "HIGH",
      "a file that is not a checkpoint at all is opened as an empty checkpoint",
      "src/tesseract_memory_db/store.mbt:817-825",
      "a caller who points the store at the wrong file gets an empty store rather than an error, and cannot tell the difference between an empty store and a wrong file.",
      `open=${facts.get("garbage_open")} entries=${facts.get("garbage_entries")}`,
    );
  }

  // (d) An empty file: a measurement, not a contract.
  log(
    `     an empty file opens as: open=${facts.get(
      "empty_open",
    )} entries=${facts.get("empty_entries")}`,
  );

  cleanup(dir);
}

/* ------------------------------------------------------------------ *
 * CHECK 2b — the same refusals, in the working tree
 * ------------------------------------------------------------------ */

/**
 * The refusals the working tree has to make.
 *
 * These are the four cases of the checkpoint format contract, and the
 * published artifact is measured against the same four in CHECK 2. The
 * working tree is measured by its own tests, and the test names are pinned
 * here: a refusal test that is renamed or deleted shows up as a *missing*
 * refusal rather than as a silent pass.
 *
 * Why the tree is measured this way and not with a probe of its own: a
 * nested module cannot reach the tree by path — `moon.mod` accepts only
 * versioned registry dependencies — so a probe of the tree would have to be a
 * package of the tree, and a package of the tree is part of the published
 * surface. A QA round that is not a release does not change the published
 * surface. The tree's refusals are therefore proved by the tree's own tests,
 * which is where they belong anyway.
 */
const TREE_REFUSALS = [
  "a checkpoint with a format version this build does not know is refused",
  "a file whose first cell is not this format's header is refused",
  "a checkpoint with no header cell at all is refused",
  "a reload of a checkpoint this build cannot read is refused, and the store keeps what it held",
];

function checkWorkingTreeCheckpoint() {
  const ID = "C2b";
  log("");
  log("=== CHECK 2b: the same refusals, in the working tree ===");

  const r = spawnSync(
    "moon",
    ["test", "--target", "native", "-v", "src/tesseract_memory_db"],
    {
      cwd: ROOT,
      encoding: "utf8",
      shell: false,
      maxBuffer: 64 * 1024 * 1024,
      timeout: 300000,
    },
  );
  const out = `${r.stdout || ""}${r.stderr || ""}`;

  // `moon test -v` prints one line per test:
  //   [riantr/tesseract] test <file>:<line> ("<name>") ok
  const results = new Map();
  for (const line of out.split(/\r?\n/)) {
    const m = /test\s+\S+:(\d+)\s+\("([^"]+)"\)\s+(ok|failed)/.exec(line);
    if (m) results.set(m[2], m[3]);
  }

  const summary = /Total tests:\s*(\d+),\s*passed:\s*(\d+),\s*failed:\s*(\d+)/.exec(
    out,
  );
  if (!summary) {
    skip(
      ID,
      "the working tree's refusals",
      `the tree's tests did not run (exit ${r.status}); nothing was measured`,
    );
    return;
  }
  log(`     tree: ${summary[1]} tests, ${summary[2]} passed, ${summary[3]} failed`);

  const missing = [];
  const failing = [];
  for (const name of TREE_REFUSALS) {
    const state = results.get(name);
    if (state === undefined) missing.push(name);
    else if (state !== "ok") failing.push(name);
  }

  if (missing.length === 0 && failing.length === 0 && summary[3] === "0") {
    pass(
      ID,
      `the working tree refuses all ${TREE_REFUSALS.length} case(s) of the checkpoint contract`,
      TREE_REFUSALS.map((n) => `ok: ${n}`).join("\n"),
    );
    return;
  }

  fail(
    ID,
    "the working tree does not refuse every case of the checkpoint contract",
    [
      missing.length ? `no such test: ${missing.join(", ")}` : "",
      failing.length ? `failing: ${failing.join(", ")}` : "",
      summary[3] !== "0" ? `${summary[3]} test(s) failed` : "",
    ]
      .filter(Boolean)
      .join("\n"),
  );
  for (const name of missing) {
    finding(
      ID,
      "HIGH",
      `the working tree has no test for a refusal the format promises: ${name}`,
      "src/tesseract_memory_db/store_test.mbt",
      "the working tree is what the next release ships, and a refusal with no test is a refusal with no proof.",
      name,
    );
  }
  for (const name of failing) {
    finding(
      ID,
      "HIGH",
      `the working tree's refusal test fails: ${name}`,
      "src/tesseract_memory_db/store_test.mbt",
      "the working tree is what the next release ships, and a refusal its own test cannot hold is not a refusal.",
      name,
    );
  }
}

/* ------------------------------------------------------------------ *
 * CHECK 3 — the SQL error-code contract
 * ------------------------------------------------------------------ */

/** The codes the source can put into a `DBResponse` or a `ParseError`. */
function emittedCodes(dir) {
  const codes = new Map(); // code -> [{ file, line }]
  const add = (code, file, line) => {
    if (!codes.has(code)) codes.set(code, []);
    codes.get(code).push({ file, line });
  };
  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".mbt") || file.endsWith("_test.mbt")) continue;
    const full = path.join(dir, file);
    const text = fs.readFileSync(full, "utf8");
    // The call is matched over the whole file, not line by line: a call whose
    // code is on the next line is the same call.
    const patterns = [
      /err_response\(\s*"([A-Z][A-Z_]*)"/g,
      /code:\s*"([A-Z][A-Z_]*)"/g,
    ];
    for (const pattern of patterns) {
      for (const m of text.matchAll(pattern)) {
        const line = text.slice(0, m.index).split(/\r?\n/).length;
        add(m[1], file, line);
      }
    }
  }
  return codes;
}

/**
 * The `{ ... }` groups in a file, each with the text that introduced it.
 *
 * Strings and line comments are skipped, so a brace inside a string literal
 * does not open a group. These groups are what the message-only rule scopes
 * itself to: an assertion belongs to the innermost group around it, and a
 * group that is a `test "..."` block is a test.
 */
function braceGroups(text) {
  const groups = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let inComment = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inComment) {
      if (c === "\n") inComment = false;
      continue;
    }
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === "/" && text[i + 1] === "/") {
      inComment = true;
      i++;
      continue;
    }
    if (c === '"') {
      inString = true;
      continue;
    }
    if (c === "{") {
      if (depth === 0) start = i;
      depth++;
      continue;
    }
    if (c === "}") {
      depth--;
      if (depth === 0 && start >= 0) {
        groups.push({
          start,
          end: i,
          header: text.slice(Math.max(0, start - 200), start),
        });
        start = -1;
      }
    }
  }
  return groups;
}

/** Is this group a MoonBit test block? */
function isTestGroup(group) {
  return /\btest\s+"[^"]*"\s*$/.test(group.header.trim());
}

/** The innermost group containing `index`, and the innermost *test* group. */
function groupsAt(groups, index) {
  let owner = null;
  let testBlock = null;
  for (const g of groups) {
    if (g.start < index && index < g.end) {
      if (!owner || g.start > owner.start) owner = g;
      if (isTestGroup(g) && (!testBlock || g.start > testBlock.start)) {
        testBlock = g;
      }
    }
  }
  return { owner, testBlock };
}

/**
 * The subject of an assertion: the value whose error it reads.
 *
 * `assert_true(r.error.contains("SAVEPOINT"))` reads the error of `r`, and
 * `assert_eq(r.error_code, "INVALID_INPUT")` reads the code of `r`. The two
 * are about the same value, and that is what pairs them.
 *
 * A subject of `null` means the assertion reads the error of something that
 * has no name — a fresh call, say. Nothing can be paired with it by name.
 */
function assertionSubject(inner) {
  const m = /([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(error_code|code|error)\b/.exec(inner);
  return m ? m[1] : null;
}

/**
 * The assertions the test suite makes.
 *
 * An assertion that reads `.error_code` (or a `ParseError`'s `.code`) is a
 * **code** assertion; one that reads only `.error` is a **message**
 * assertion. The difference is what a caller can branch on.
 *
 * The scope is the **test**, and the pairing is by **value**. A message
 * assertion is a finding unless the same test asserts on the code of the
 * same value: `assert_eq(r.error_code, "INVALID_INPUT")` on the line above
 * `assert_true(r.error.contains("SAVEPOINT"))` has pinned the code, and the
 * wording assertion is extra, not a gap.
 *
 * Scoping it per assertion would report a test as missing something it has.
 * Scoping it per test alone would be too coarse: a test that pins the code
 * of one value and reads only the message of another has still left the
 * second one's code unpinned, and a change to it would pass the suite.
 */
function testAssertions(dir, knownCodes) {
  const codeAsserted = new Map(); // code -> [{ file, line }]
  const messageOnly = [];
  let codeAssertions = 0;
  let messageAssertions = 0;
  let messageWithCode = 0;

  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith("_test.mbt")) continue;
    const full = path.join(dir, file);
    const text = fs.readFileSync(full, "utf8");
    const groups = braceGroups(text);
    // region key -> { subjects: Set<string>, anyCode: bool, messages: [] }
    const regions = new Map();

    const starts = [...text.matchAll(/\b(assert_eq|assert_true|assert_false|assert_not_eq)\s*\(/g)];
    for (const s of starts) {
      const open = text.indexOf("(", s.index);
      const close = matchParen(text, open);
      if (close < 0) continue;
      const inner = text.slice(open + 1, close);
      const lineNo = text.slice(0, open).split(/\r?\n/).length;
      const isCode = /\.error_code\b/.test(inner) || /\.code\b/.test(inner);
      const subject = assertionSubject(inner);

      const { owner, testBlock } = groupsAt(groups, open);
      const region = testBlock || owner;
      const key = region ? `${region.start}:${region.end}` : "file";
      if (!regions.has(key)) {
        regions.set(key, { subjects: new Set(), anyCode: false, messages: [] });
      }
      const bucket = regions.get(key);

      if (isCode) {
        codeAssertions++;
        bucket.anyCode = true;
        if (subject) bucket.subjects.add(subject);
        for (const m of inner.matchAll(/"([A-Z][A-Z_]*)"/g)) {
          if (!knownCodes.has(m[1])) continue;
          if (!codeAsserted.has(m[1])) codeAsserted.set(m[1], []);
          codeAsserted.get(m[1]).push({ file, line: lineNo });
        }
      } else if (/\.error\b/.test(inner)) {
        messageAssertions++;
        bucket.messages.push({
          file,
          line: lineNo,
          subject,
          text: inner.replace(/\s+/g, " ").trim().slice(0, 90),
        });
      }
    }

    for (const region of regions.values()) {
      for (const m of region.messages) {
        // Paired with a code assertion on the same value in the same test. An
        // assertion on a value with no name is excused by any code assertion
        // in the test, because there is no name to pair it by.
        const excused =
          m.subject === null
            ? region.anyCode
            : region.subjects.has(m.subject);
        if (excused) messageWithCode++;
        else messageOnly.push(m);
      }
    }
  }
  return {
    codeAsserted,
    messageOnly,
    codeAssertions,
    messageAssertions,
    messageWithCode,
  };
}

function checkErrorCodes() {
  const ID = "C3";
  log("");
  log("=== CHECK 3: SQL error-code contract ===");

  const srcDir = path.join(ROOT, "src", "tesseract");
  const codes = emittedCodes(srcDir);
  const list = [...codes.keys()].sort();
  log(`     codes the source can emit: ${list.length}`);
  for (const code of list) {
    const sites = codes.get(code);
    log(
      `       ${code} (${sites.length} site${sites.length === 1 ? "" : "s"}: ${sites
        .map((s) => `${s.file}:${s.line}`)
        .join(", ")})`,
    );
  }

  // The README's list — the vocabulary is also a promise in the documentation.
  const readme = fs.readFileSync(path.join(ROOT, "README.mbt.md"), "utf8");
  const readmeLine = readme
    .split(/\r?\n/)
    .findIndex((l) => l.includes("Error codes:"));
  const readmeBlock =
    readmeLine >= 0
      ? readme.split(/\r?\n/).slice(readmeLine, readmeLine + 6).join(" ")
      : "";
  const readmeCodes = new Set(
    [...readmeBlock.matchAll(/`([A-Z][A-Z_]*)`/g)].map((m) => m[1]),
  );
  log(
    `     codes the README documents: ${readmeCodes.size} (README.mbt.md:${readmeLine + 1})`,
  );

  const known = new Set(list);
  const {
    codeAsserted,
    messageOnly,
    codeAssertions,
    messageAssertions,
    messageWithCode,
  } = testAssertions(srcDir, known);

  log(`     code assertions in the test suite: ${codeAssertions}`);
  log(
    `     message assertions in the test suite: ${messageAssertions} (${messageWithCode} of them in a test that also pins a code)`,
  );

  const notAsserted = list.filter((c) => !codeAsserted.has(c));
  const notDocumented = list.filter((c) => !readmeCodes.has(c));
  const documentedNotEmitted = [...readmeCodes].filter((c) => !known.has(c));

  for (const code of notDocumented) {
    finding(
      "C3.1",
      "MEDIUM",
      `the source can emit ${code}, but the README does not list it`,
      `README.mbt.md:${readmeLine + 1}`,
      "the README says the list is the complete set the port emits; a code outside it is a code a consumer cannot look up.",
      code,
    );
  }
  for (const code of documentedNotEmitted) {
    finding(
      "C3.2",
      "MEDIUM",
      `the README lists ${code}, but the source never emits it`,
      `README.mbt.md:${readmeLine + 1}`,
      "a documented code that cannot happen is a code a consumer writes a branch for and never sees.",
      code,
    );
  }

  for (const code of notAsserted) {
    finding(
      "C3.3",
      "HIGH",
      `the source can emit ${code}, but no test asserts on the code`,
      `src/tesseract/ (${codes.get(code).map((s) => `${s.file}:${s.line}`).join(", ")})`,
      "the code is part of the package's contract with its callers, and nothing in the suite holds it in place; a change to the code would pass the suite.",
      code,
    );
  }

  if (messageOnly.length > 0) {
    for (const m of messageOnly) {
      finding(
        "C3.4",
        "LOW",
        "a test reads an error's message but never that error's code",
        `src/tesseract/${m.file}:${m.line}`,
        "the message is prose and may be reworded; the code is the part a caller branches on. This test asserts on the message of a value whose code it never asserts on, so the code behind that message could change to a different one of the twelve and this test would still pass.",
        m.text,
      );
    }
  }

  const assertedCount = list.length - notAsserted.length;
  log(
    `     codes asserted on the code: ${assertedCount} of ${list.length}${
      notAsserted.length > 0 ? ` (not asserted: ${notAsserted.join(", ")})` : ""
    }`,
  );

  if (notAsserted.length > 0 || notDocumented.length > 0 || documentedNotEmitted.length > 0) {
    fail(
      ID,
      `the SQL error-code vocabulary is not fully covered: ${assertedCount}/${list.length} codes asserted on the code, ${notDocumented.length} undocumented, ${documentedNotEmitted.length} documented but unemitted`,
    );
  } else {
    pass(
      ID,
      `the SQL error-code vocabulary is closed and covered: ${list.length} codes, ${assertedCount} asserted on the code`,
    );
  }

  if (messageOnly.length > 0) {
    log(
      `       ${messageOnly.length} message-only assertion(s): ${messageOnly
        .map((m) => `${m.file}:${m.line}`)
        .join(", ")}`,
    );
  }
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */

await checkPublishedSurface();
checkCheckpointFormat();
checkWorkingTreeCheckpoint();
checkErrorCodes();

const treeFindings = findings.filter((f) => f.scope !== "published" && f.scope !== "drift");
const publishedFindings = findings.filter((f) => f.scope === "published");
const driftFindings = findings.filter((f) => f.scope === "drift");

function printFinding(f) {
  log(`  [${f.id}] (${f.severity}) ${f.what}`);
  log(`       where:    ${f.where}`);
  log(`       why:      ${f.why}`);
  log(`       observed: ${f.observed}`);
}

log("");
log("=== findings (working tree) ===");
if (treeFindings.length === 0) {
  log("     none");
} else {
  for (const f of treeFindings) printFinding(f);
}

log("");
log(`=== findings (published ${PUBLISHED_VERSION}) ===`);
if (publishedFindings.length === 0) {
  log("     none");
} else {
  for (const f of publishedFindings) printFinding(f);
  log("");
  log(
    `     these ${publishedFindings.length} describe the artifact on the registry, not the tree.`,
  );
  log(
    "     a release closes the behavioural ones; the rest are standing issues of the",
  );
  log(
    "     registry's index, which a re-publish reproduces, and are not this repo's to fix.",
  );
}

log("");
log("=== drift (the tree has moved on; the registry has not) ===");
if (driftFindings.length === 0) {
  log("     none");
} else {
  for (const f of driftFindings) printFinding(f);
  log("");
  log(
    `     these ${driftFindings.length} are what the next release reconciles. A symbol the`,
  );
  log(
    "     registry advertises and the source no longer has breaks a consumer at the",
  );
  log("     version boundary, so each one belongs in the release notes.");
}

log("");
log(
  `${treeFindings.length} finding(s) in the working tree, ${publishedFindings.length} in the published artifact, ${driftFindings.length} in the drift; ${
    failed || treeFindings.length > 0
      ? "the working tree has something to fix"
      : "the working tree is clean"
  }`,
);

if (failed || treeFindings.length > 0) process.exitCode = 1;
