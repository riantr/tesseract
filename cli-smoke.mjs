// End-to-end smoke test for the two CLIs.
//
//   node cli-smoke.mjs
//
// Builds both binaries for `native` and drives them as real processes, so this
// covers the argv handling and the persistence path rather than the library,
// which `moon test` already covers. The window has `gui-smoke.mjs`; these two
// binaries had no gate at all, which is how `.open sudoku.db` could fail to
// open and `.export md` could quietly write an .tsr file under a .md name.
//
// Every argument here is passed as its own argv entry, the way a shell splits
// it. That is the whole point: a command and its argument reach the program as
// two strings, and matching only the joined form is what broke both CLIs.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = path.dirname(fileURLToPath(import.meta.url));

const log = (...a) => console.log(...a);
const head = (s, n = 4) => (s || "").split(/\r?\n/).slice(0, n).join(" / ");

let failures = 0;
function check(name, got, want, extra) {
  const ok = got === want;
  if (!ok) failures++;
  log(
    `${ok ? "PASS" : "FAIL"}  ${name}` +
      (ok
        ? ""
        : `\n        got:  ${JSON.stringify(got)}\n        want: ${JSON.stringify(want)}` +
          (extra ? `\n        ctx:  ${head(extra, 6)}` : "")),
  );
}

function moon(args) {
  const r = spawnSync("moon", args, { cwd: ROOT, encoding: "utf8", shell: true });
  if (r.status !== 0) throw new Error(`moon ${args.join(" ")} failed:\n${r.stdout}\n${r.stderr}`);
}

function exe(pkg) {
  const p = path.join(
    ROOT,
    "_build",
    "native",
    "debug",
    "build",
    "cmd",
    pkg,
    process.platform === "win32" ? `${pkg}.exe` : pkg,
  );
  if (!fs.existsSync(p)) throw new Error("missing binary: " + p);
  return p;
}

function run(pkg, args, cwd) {
  const r = spawnSync(exe(pkg), args, { cwd, encoding: "utf8" });
  return { out: r.stdout || "", err: r.stderr || "", code: r.status };
}

const SQL_ADD =
  "INSERT INTO tesseract (key,value,digit) VALUES ('u_probe','v1',1) AT 1;";
const SELECT_ALL = "SELECT * FROM tesseract;";

// `格式: 时间: 1` - only a rendered record carries one, never an INSERT reply.
const stampOf = (out, key) => {
  const m = new RegExp(key + "[\\s\\S]*?时间:\\s*(\\d+)").exec(out);
  return m ? m[1] : null;
};

function main() {
  log("building cmd/main and cmd/persist for native...");
  moon(["build", "cmd/main", "--target", "native"]);
  moon(["build", "cmd/persist", "--target", "native"]);

  // A scratch directory this script owns outright, so it can clean up after
  // itself without touching anything of yours.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tesseract-cli-"));
  try {
    // ---- cmd/main: a command and its format arrive as two argv entries ----
    let r = run("main", ["INSERT INTO tesseract (key,value) VALUES ('a','1') AT 5;", ".export", "md"], dir);
    // Pre-fix, bare `.export` exported the default format and `md` ran as SQL.
    check("`.export md` exports Markdown, not the default format", r.out.startsWith("# Tesseract 4D"), true, r.out);
    // Both streams: once `.export` has run it sends everything else to stderr,
    // so the failed parse of `md` would not show up in stdout at all.
    check("`.export md` does not run `md` as SQL", (r.out + r.err).includes("Unsupported SQL statement"), false, r.out + r.err);

    r = run("main", [".export", "sql"], dir);
    check("`.export sql` exports a SQL dump", r.out.startsWith("-- Tesseract 4D export"), true, r.out);

    r = run("main", [".export"], dir);
    check("`.export` on its own still defaults to .tsr", r.out.trimStart().startsWith("{"), true, r.out);

    // ---- cmd/persist: `.open` takes a path, and it is a separate argv entry ----
    const xdb = path.join(dir, "x.db");
    r = run("persist", [".open", "x.db"], dir);
    check("`.open x.db` opens the file", r.out.includes("opened x.db"), true, r.out + r.err);
    check("`.open` no longer falls through to the SQL parser", r.out.includes("Unsupported SQL statement"), false, r.out + r.err);

    r = run("persist", [".open", "x.db", SQL_ADD, ".save"], dir);
    // Pre-fix, `.save` had no path because `.open` never succeeded, so this
    // warned instead of writing - which is how a "saved" run left no file.
    check("a bare `.save` writes back to the file `.open` took", r.out.includes("saved 1 record(s) to x.db"), true, r.out + r.err);
    check("that save produced a non-empty file", fs.existsSync(xdb) && fs.statSync(xdb).size > 0, true);

    // `.save`'s argument is optional, so a following command must not be eaten
    // as the path. A join that ignored this would write a file named `.status`.
    r = run("persist", [".open", "x.db", ".save", ".status"], dir);
    check("a bare `.save` does not swallow the `.status` after it", fs.existsSync(path.join(dir, ".status")), false, r.out + r.err);
    check("...and `.status` still reports", r.out.includes("records : 1"), true, r.out + r.err);

    // ---- timestamps survive a real process boundary ----
    r = run("persist", [".open", "x.db", SQL_ADD, SELECT_ALL, ".save"], dir);
    const stampedA = stampOf(r.out, "u_probe");
    check("process A stamped the cell", stampedA !== null, true, r.out);

    // B advances its own log counter *before* opening, because the load happens
    // inside `.open` and there is otherwise nothing to separate the two paths:
    // both processes would mint the same stamp for the same operation sequence
    // and the check would pass whether or not the file's stamp was restored.
    r = run(
      "persist",
      [SELECT_ALL, SELECT_ALL, SELECT_ALL, SELECT_ALL, SELECT_ALL, ".open", "x.db", SELECT_ALL,
       "INSERT INTO tesseract (key,value,digit) VALUES ('u_marker','m',0) AT 37;", SELECT_ALL],
      dir,
    );
    const loadedB = stampOf(r.out, "u_probe");
    const markerB = stampOf(r.out, "u_marker");
    check("a reopened cell keeps the stamp the file was saved with", loadedB, stampedA, r.out);
    // The perturbation check: if B's counter had not actually moved past the
    // saved stamp, the line above would hold for the wrong reason.
    check("B's counter really had moved past the saved stamp", markerB !== null && Number(markerB) > Number(stampedA), true, r.out);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }

  log("");
  log(failures === 0 ? "all cli smoke checks passed" : `${failures} cli smoke check(s) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

try {
  main();
} catch (e) {
  console.error("cli smoke test failed to run:", e.message);
  process.exit(2);
}
