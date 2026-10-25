# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Releasing

- **The README is a symlink.** `README.md` points at `README.mbt.md`, which
  holds the real content and is the file `moon.mod` names as `readme`. Edit
  `README.mbt.md`. Writing to `README.md` replaces the symlink with a regular
  file, and the two then drift apart.

- **Move the dependency pins by hand.** `moon update` refreshes the registry
  index; it does not move the `import` block in `moon.mod`. Edit that block,
  then run the whole gate **under the new pins** — being green under the old
  ones does not count.

- **The gate**, in the order it is run:

  ```
  moon fmt --check
  moon check --target wasm --deny-warn
  moon check --target js --deny-warn
  moon check --target native --deny-warn
  moon check --target wasm-gc --deny-warn
  moon test --target wasm --deny-warn
  moon build --target wasm
  typos
  node cli-smoke.mjs
  node gui-smoke.mjs
  ```

  `gui-smoke.mjs` starts `proton_cli dev` itself, and `proton_cli` inherits the
  working directory and looks for `proton.project.json` there — so it has to be
  run **from the repository root** or the app never starts.

- **The nested modules carry their own gate, and the gate above does not see
  them.** `qa/fuzz` and `qa/contract_probe` have their own `moon.mod`, so the
  root module's `moon fmt --check` and `moon check` never touch them — and
  both of them were unformatted for as long as they existed. Each one has to
  be gated separately:

  ```
  cd qa/contract_probe && moon fmt --check && moon check --target native --deny-warn && moon test --target native
  cd qa/fuzz && moon fmt --check && moon check --target native --deny-warn && moon test --target native
  ```

  They are also the only two places that build against the **published**
  package rather than the tree, so their tests are the only ones that can see
  a release breaking a consumer.

- **The order of a release is fixed.** Update the dependencies, get the gate
  green, *then* update the README, and only then cut the tag. A README that
  describes a version the registry does not carry is worse than a stale one.

- **gitee is the daily remote; github is the release remote.** Push master and
  the tag to gitee first, then to github. The tag push to github is what
  triggers `.github/workflows/publish.yml`, which is the only supported way to
  publish — never `moon publish` by hand. `moon.mod`'s `version` must equal the
  tag without its `v`; the workflow checks that and fails the release if they
  disagree.
