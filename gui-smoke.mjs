// End-to-end smoke test for the SudokuDB window.
//
//   proton_cli dev            # in one terminal, PROTON_HEADLESS=1 is fine
//   node gui-smoke.mjs        # in another
//
// Proton exposes a Chromium remote-debugging endpoint while the app runs. This
// script finds the page target through it and drives the real UI: it clicks the
// real buttons and asserts on what the page then renders. That exercises the
// whole path - HTML -> __MoonBit__ -> typed command -> lattice -> JSON reply -
// rather than just proving the binary starts.

import { spawn } from "node:child_process";

const PORT = process.env.PROTON_DEVTOOLS_PORT || "";
const URL_PREFIX = process.env.SUDOKUDB_URL_PREFIX || "cmd/gui/web/index.html";

const log = (...a) => console.log(...a);

// proton_cli spawns the app as a grandchild, so killing it is not enough:
// a surviving gui.exe keeps gui.exe locked and the next build fails to link.
function killTree(pid) {
  if (process.platform === "win32") {
    spawn("taskkill", ["/F", "/T", "/PID", String(pid)], { stdio: "ignore" });
  } else {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {}
  }
}

function startApp() {
  const proc = spawn("proton_cli", ["dev"], {
    shell: true,
    env: { ...process.env, PROTON_HEADLESS: "1" },
  });
  let buf = "";
  proc.stdout.on("data", (d) => {
    buf += d;
    process.stdout.write("[app] " + d);
  });
  proc.stderr.on("data", (d) => {
    buf += d;
    process.stderr.write("[app] " + d);
  });
  return { proc, port: () => (PORT || (buf.match(/127\.0\.0\.1:(\d+)\/devtools/) || [])[1]) };
}

async function pageTarget(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  const list = await res.json();
  return list.find((t) => t.type === "page" && t.url.includes(URL_PREFIX)) ||
    list.find((t) => t.type === "page");
}

class Cdp {
  #ws;
  #id = 0;
  #pending = new Map();
  constructor(ws) {
    this.#ws = ws;
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      const slot = this.#pending.get(msg.id);
      if (slot) {
        this.#pending.delete(msg.id);
        msg.error ? slot.reject(new Error(JSON.stringify(msg.error))) : slot.resolve(msg.result);
      }
    });
  }
  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((res, rej) => {
      ws.addEventListener("open", res, { once: true });
      ws.addEventListener("error", rej, { once: true });
    });
    return new Cdp(ws);
  }
  send(method, params = {}) {
    const id = ++this.#id;
    this.#ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.#pending.set(id, { resolve, reject }));
  }
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (r.exceptionDetails) {
      throw new Error(
        "page threw: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text),
      );
    }
    return r.result.value;
  }
}

let failures = 0;
function check(name, got, want, extra) {
  const ok = got === want;
  if (!ok) failures++;
  log(
    `${ok ? "PASS" : "FAIL"}  ${name}` +
      (ok ? "" : `\n        got:  ${JSON.stringify(got)}\n        want: ${JSON.stringify(want)}` + (extra ? `\n        ctx:  ${extra}` : "")),
  );
}

const chips = (cdp) => cdp.eval("document.getElementById('chips').innerText.replace(/\\n/g,' | ')");
const resp = (cdp) => cdp.eval("document.getElementById('outResp').innerText.replace(/\\n/g,' | ')");

async function main() {
  const { proc, port } = startApp();
  let cdp;
  try {
    const ready = Date.now() + 120000;
    let port_ = null;
    while (Date.now() < ready) {
      port_ = port();
      if (port_) break;
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!port_) throw new Error("no DevTools endpoint appeared on stderr");

    let target = null;
    while (Date.now() < ready) {
      try {
        target = await pageTarget(port_);
        if (target) break;
      } catch {}
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!target) throw new Error("no page target");
    cdp = await Cdp.connect(target.webSocketDebuggerUrl);
    await cdp.send("Runtime.enable");

    // Wait for the first paint driven by app:state.
    for (let i = 0; i < 60; i++) {
      const chips = await cdp.eval("document.getElementById('chips').innerText");
      if (chips && chips.includes("记录")) break;
      await new Promise((r) => setTimeout(r, 500));
    }

    check("chips rendered from app:state", await cdp.eval("document.getElementById('chips').innerText.includes('记录')"), true);
    check("plane is 9 cells", await cdp.eval("document.querySelectorAll('#grid .cell').length"), 9);
    check("first cell is empty", await cdp.eval("document.querySelector('#grid .cell').classList.contains('empty')"), true);
    check("occupancy starts at 0/81", await cdp.eval("document.getElementById('chips').innerText.includes('0 / 81')"), true, await chips(cdp));

    // A plain insert through the real button.
    await cdp.eval(`(() => {
      document.getElementById('fKey').value = 'smoke_key';
      document.getElementById('fValue').value = '{"n": 1}';
      document.getElementById('fPos').value = '1';
      document.getElementById('btnInsert').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    check("insert reached the store", await cdp.eval("document.getElementById('chips').innerText.includes('1 / 81')"), true, (await chips(cdp)) + " || " + (await resp(cdp)));
    check("cell 1 now holds the key", await cdp.eval("document.querySelector('#grid .cell').innerText.includes('smoke_key')"), true);

    // An out-of-range position must be an error, not a silent write to the
    // insert cursor. The library already answers INVALID_POSITION for this; the
    // window must not paper over it.
    await cdp.eval(`(() => {
      document.getElementById('fKey').value = 'oob';
      document.getElementById('fValue').value = 'v';
      document.getElementById('fPos').value = '999';
      document.getElementById('btnInsert').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    check(
      "out-of-range position is refused",
      await cdp.eval("document.getElementById('outResp').innerText.includes('INVALID_POSITION')"),
      true,
      await resp(cdp),
    );
    check("out-of-range write changed nothing", await cdp.eval("document.getElementById('chips').innerText.includes('1 / 81')"), true, await chips(cdp));

    // 删除 with an empty form must not become the library's clear-everything
    // form; that is what 清空整个点阵 is for.
    await cdp.eval(`(() => {
      document.getElementById('fKey').value = '';
      document.getElementById('fValue').value = '';
      document.getElementById('fPos').value = '';
      document.getElementById('btnDelete').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    check(
      "empty-form delete is refused",
      await cdp.eval("document.getElementById('outResp').innerText.includes('INVALID_INPUT')"),
      true,
      await resp(cdp),
    );
    check("empty-form delete did not wipe", await cdp.eval("document.getElementById('chips').innerText.includes('1 / 81')"), true, await chips(cdp));

    // The sudoku rule, through the real digit buttons. Cell 1 takes digit 1
    // first; cell 3 shares the w-axis line with it, so the same digit there
    // has to be refused.
    await cdp.eval(`(() => {
      document.querySelectorAll('#grid .cell')[0].click();
      document.querySelector('.digits button[data-d="1"]').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    // Asserting occupancy here would be vacuous: the insert above already made
    // it 1/81, so "1 / 81" passes whether or not the digit landed. The badge
    // is what actually says the digit was accepted.
    check(
      "digit 1 accepted on cell 1",
      await cdp.eval("(document.querySelector('#grid .cell .digit') || {}).textContent || ''"),
      "1",
      (await chips(cdp)) + " || " + (await resp(cdp)),
    );

    await cdp.eval(`(() => {
      document.querySelectorAll('#grid .cell')[2].click();
      document.querySelector('.digits button[data-d="1"]').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    check(
      "digit 1 refused on a shared line",
      await cdp.eval("document.getElementById('outResp').innerText.includes('SUDOKU_CONFLICT')"),
      true,
      await resp(cdp),
    );

    // A legal digit, and the geometry query.
    await cdp.eval(`(() => {
      document.querySelector('.digits button[data-d="2"]').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    check("digit 2 accepted on cell 3", await cdp.eval("document.getElementById('chips').innerText.includes('2 / 81')"), true, (await chips(cdp)) + " || " + (await resp(cdp)));

    await cdp.eval("document.getElementById('btnGeo').click(); true");
    await new Promise((r) => setTimeout(r, 1200));
    check("peer query covers 8 cells", await cdp.eval("/覆盖 8 格/.test(document.getElementById('geoOut').innerText)"), true, await cdp.eval("document.getElementById('geoOut').innerText"));

    // The digit select and the digit row are two controls for the same field,
    // and they used to disagree: the row sent an explicit 0 (which clears) and
    // the select omitted it (which keeps the old value). Cell 3 carries digit
    // 2; setting the select to 无 and pressing 更新 must drop it.
    await cdp.eval(`(() => {
      document.querySelectorAll('#grid .cell')[2].click();
      document.getElementById('fDigit').value = '0';
      document.getElementById('btnUpdate').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    check(
      "digit select 无 clears the digit",
      await cdp.eval("document.querySelectorAll('#grid .cell')[2].querySelector('.digit') === null"),
      true,
      (await chips(cdp)) + " || " + (await resp(cdp)),
    );
    check("digit count follows the clear", await cdp.eval("document.getElementById('chips').innerText.includes('数位1')"), true, await chips(cdp));

    // 清除 on a cell that carries nothing must not create the `cell_N` record
    // the insert branch used to make. Cell 2 is empty; if it gained a record
    // its `empty` class would be gone, so that is what is asserted.
    await cdp.eval(`(() => {
      document.querySelectorAll('#grid .cell')[1].click();
      document.querySelector('.digits button[data-d="0"]').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    check(
      "清除 on an empty cell leaves it empty",
      await cdp.eval("document.querySelectorAll('#grid .cell')[1].classList.contains('empty')"),
      true,
      (await chips(cdp)) + " || " + (await resp(cdp)),
    );
    check(
      "清除 on an empty cell says so",
      await cdp.eval("document.getElementById('outResp').innerText.includes('本来就是空的')"),
      true,
      await resp(cdp),
    );

    // SQL through the real console.
    await cdp.eval(`(() => {
      document.getElementById('sql').value = "SELECT * FROM sudokuDB;";
      document.getElementById('btnSql').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    check("SQL rows rendered", await cdp.eval("document.querySelectorAll('#pane-rows tbody tr').length"), 2, await cdp.eval("document.getElementById('outRows').innerText.slice(0,200)"));

    // A SQL statement must not move the user off the plane they are looking
    // at, and the plane selectors must agree with the grid.
    await cdp.eval(`(() => {
      const sx = document.getElementById('selX');
      const sy = document.getElementById('selY');
      sx.value = '1';
      sx.dispatchEvent(new Event('change'));
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    await cdp.eval(`(() => {
      const sy = document.getElementById('selY');
      sy.value = '1';
      sy.dispatchEvent(new Event('change'));
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    const planeBefore = await cdp.eval("document.getElementById('selX').value + ',' + document.getElementById('selY').value");
    check("plane switched to 1,1", planeBefore, "1,1");
    // The selection is a position, and position 3 names a different cell in the
    // new plane - so carrying it over highlights a cell the page has already
    // disowned. The form is cleared with it: a stale key would let a DELETE land
    // on a cell that is no longer on screen.
    check(
      "plane switch clears the selection",
      await cdp.eval("document.querySelector('#grid .cell.sel') === null"),
      true,
      await cdp.eval("document.getElementById('inspect').innerText"),
    );
    check(
      "plane switch clears the write form",
      await cdp.eval("document.getElementById('fKey').value + '|' + document.getElementById('fPos').value"),
      "|",
      "key=" +
        (await cdp.eval("document.getElementById('fKey').value")) +
        " pos=" +
        (await cdp.eval("document.getElementById('fPos').value")),
    );
    await cdp.eval(`(() => {
      document.getElementById('sql').value = "SELECT * FROM sudokuDB;";
      document.getElementById('btnSql').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1500));
    check(
      "SQL keeps the current plane",
      await cdp.eval("document.getElementById('selX').value + ',' + document.getElementById('selY').value"),
      "1,1",
      await cdp.eval("document.getElementById('chips').innerText.replace(/\\n/g,' | ')"),
    );
    // Back to the origin plane for the remaining checks.
    await cdp.eval(`(() => {
      const sx = document.getElementById('selX');
      const sy = document.getElementById('selY');
      sx.value = '0';
      sx.dispatchEvent(new Event('change'));
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    await cdp.eval(`(() => {
      const sy = document.getElementById('selY');
      sy.value = '0';
      sy.dispatchEvent(new Event('change'));
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));

    // A key with no position is the library's delete-every-cell-carrying-that-
    // key form. This button is framed around one cell, so it has to say the
    // form was refused rather than silently removing rows that are not shown.
    // S.sel is null here because the plane switch cleared it.
    await cdp.eval(`(() => {
      document.getElementById('fKey').value = 'user_002';
      document.getElementById('fValue').value = '';
      document.getElementById('fPos').value = '';
      document.getElementById('btnDelete').click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 1200));
    check(
      "key-only delete is refused at the page",
      await cdp.eval("document.getElementById('outResp').innerText.includes('删除按格进行')"),
      true,
      await resp(cdp),
    );

    // The demo tour must end in the same store the CLI's `.demo` ends in:
    // two records, one digit, user_001 overwritten by d1 at position 1,
    // user_002 untouched at age 30, user_003 deleted. Verified against
    // `moon run cmd/main -- .demo`, which reports records 2 / digits 1.
    await cdp.eval("document.getElementById('btnDemo').click(); true");
    await new Promise((r) => setTimeout(r, 4000));
    check("demo leaves 2 records", await cdp.eval("document.getElementById('chips').innerText.includes('2 / 81')"), true, (await chips(cdp)) + " || " + (await resp(cdp)));
    check("demo leaves 1 digit", await cdp.eval("document.getElementById('chips').innerText.includes('数位1')"), true, await chips(cdp));
    check(
      "demo leaves user_002 at age 30, as the CLI does",
      await cdp.eval("document.querySelectorAll('#grid .cell')[1].innerText.includes('{\\\"age\\\": 30}')"),
      true,
      await cdp.eval("document.querySelectorAll('#grid .cell')[1].innerText.replace(/\\n/g,' | ')"),
    );

    // The closed-form solve, which is the CLI's `.solve`. Clear first: the closed
    // form can only overwrite a cell whose current digit does not clash with a
    // neighbour's, so a half-finished puzzle legitimately refuses some
    // positions - the response says which.
    await cdp.eval("document.getElementById('btnClear').click(); true");
    await new Promise((r) => setTimeout(r, 1200));
    check("clear emptied the lattice", await cdp.eval("document.getElementById('chips').innerText.includes('0 / 81')"), true, await chips(cdp));

    await cdp.eval("document.getElementById('btnSolve').click(); true");
    for (let i = 0; i < 40; i++) {
      if ((await chips(cdp)).includes("81 / 81")) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    check("solve filled all 81", await cdp.eval("document.getElementById('chips').innerText.includes('81 / 81')"), true, (await chips(cdp)) + " || " + (await resp(cdp)));
    check(
      "solved lattice is a valid solution",
      await cdp.eval("document.getElementById('chips').innerText.includes('完整解')"),
      true,
      await chips(cdp),
    );

    // Export round trip.
    await cdp.eval("document.getElementById('btnExport').click(); true");
    await new Promise((r) => setTimeout(r, 2000));
    check("export produced .sdb text", await cdp.eval("document.getElementById('ioText').value.length > 100"), true);

    log("");
    log(failures === 0 ? "all smoke checks passed" : `${failures} smoke check(s) FAILED`);
  } finally {
    try {
      killTree(proc.pid);
    } catch {}
    await new Promise((r) => setTimeout(r, 1500));
    process.exit(failures === 0 ? 0 : 1);
  }
}

main().catch((e) => {
  console.error("smoke test failed to run:", e.message);
  process.exit(2);
});