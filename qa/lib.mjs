// Shared helpers for the QA harness.
//
// Every tool in this directory drives the **built binaries** as real
// processes, or reads the artifacts the compiler left behind. Nothing here
// reaches into the source to guess at behaviour: a QA number that is not
// measured is a guess, and a guess in a QA report is worse than no number.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export const log = (...a) => console.log(...a);

/** Builds a binary for `native` and returns its path. */
export function build(pkg) {
  const r = spawnSync("moon", ["build", pkg, "--target", "native"], {
    cwd: ROOT,
    encoding: "utf8",
    shell: true,
  });
  if (r.status !== 0) {
    throw new Error(`moon build ${pkg} failed:\n${r.stdout}\n${r.stderr}`);
  }
  return exe(pkg);
}

/**
 * The path of a built binary.
 *
 * `moon build` takes the package path (`cmd/main`) and the artifact lands
 * under the package's own name (`main`), so the two are different words and
 * the path is assembled from the last segment of the package path.
 */
export function exe(pkg) {
  const name = pkg.split("/").pop();
  const p = path.join(
    ROOT,
    "_build",
    "native",
    "debug",
    "build",
    pkg,
    process.platform === "win32" ? `${name}.exe` : name,
  );
  if (!fs.existsSync(p)) throw new Error("missing binary: " + p);
  return p;
}

/**
 * Runs a binary and says what happened.
 *
 * `timeoutMs` is the interesting part: a program that never returns is a
 * defect, not a slow test, and the only way to see it is to stop waiting.
 */
export function run(pkg, args, cwd, timeoutMs = 10000) {
  const started = Date.now();
  let r;
  try {
    r = spawnSync(exe(pkg), args, {
      cwd,
      encoding: "utf8",
      timeout: timeoutMs,
      killSignal: "SIGKILL",
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (e) {
    // An argument the operating system cannot carry at all — a NUL byte in
    // argv, which is how argv is terminated. That is not a defect in the
    // program under test; it is a vector this platform cannot deliver, and
    // saying so is more useful than crashing the probe.
    return {
      out: "",
      err: "",
      code: null,
      signal: null,
      error: `undeliverable: ${e.message}`,
      ms: Date.now() - started,
    };
  }
  return {
    out: r.stdout || "",
    err: r.stderr || "",
    code: r.status,
    signal: r.signal || null,
    error: r.error ? String(r.error.message || r.error) : null,
    ms: Date.now() - started,
  };
}

/** A scratch directory this process owns outright. */
export function scratch(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `tesseract-qa-${tag}-`));
}

/** Removes a scratch directory. */
export function cleanup(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
}

/**
 * The NTSTATUS codes that mean "the program fell over" on Windows.
 */
const CRASH_STATUSES = new Set([
  "C0000005", // access violation
  "C0000409", // stack buffer overrun / Rust panic abort
  "C0000374", // heap corruption
  "C000001D", // illegal instruction
  "C0000094", // integer divide by zero
  "C000008C", // array bounds exceeded
]);

/**
 * What the run means.
 *
 * The three answers are kept apart on purpose, because collapsing them is
 * how a QA harness reports a defect that is not there:
 *
 * - `undeliverable` — the **operating system** refused the request and the
 *   program never started. A command line longer than the OS limit is
 *   refused before `main` is reached, and calling that a crash would be
 *   blaming the program for something it never saw.
 * - `hung` — the program **started** and never returned, so the timeout
 *   killed it. That is a defect: an input a person can type must not make
 *   the program look busy forever.
 * - `crashed` — the program started and died abnormally. Also a defect.
 *
 * `null` means the program started and returned, which is the only answer
 * that is not a finding.
 */
export function classify(r) {
  if (r.error) return { kind: "undeliverable", detail: r.error };
  if (r.signal) return { kind: "hung", detail: `killed by ${r.signal} after the timeout` };
  if (r.code === null) return { kind: "crashed", detail: "no exit code" };
  if (r.code < 0) {
    const status = (r.code >>> 0).toString(16).toUpperCase();
    if (CRASH_STATUSES.has(status)) {
      return { kind: "crashed", detail: `abnormal exit 0x${status}` };
    }
  }
  return null;
}

/** The lines of a text file, without the trailing newline. */
export function readLines(file) {
  return fs.readFileSync(file, "utf8").split(/\r?\n/);
}

/**
 * The source files of the module, excluding build output and the vendored deps.
 *
 * A directory holding its own `moon.mod` is a **nested module** - a module of
 * its own with its own gate and its own tests. `qa/fuzz` is one. It is not
 * part of this module, so its files are not this module's sources, and
 * counting its tests as this module's tests would overstate the suite by
 * however many it has.
 */
export function sourceFiles() {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (["_build", ".mooncakes", ".git", "node_modules", "_coverage"].includes(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (full !== ROOT && fs.existsSync(path.join(full, "moon.mod"))) continue;
        walk(full);
      } else if (entry.name.endsWith(".mbt")) out.push(full);
    }
  };
  walk(ROOT);
  return out;
}
