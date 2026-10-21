// Tesseract, migrated to MoonBit at 4 dimensions.
//
// The core library in this toolchain carries no file I/O and no stdin reader, so
// `src/tesseract` and `cmd/main` implement everything they need rather than
// pulling it in, and stay dependency-free. It does carry two core packages -
// `@env.now()` from `moonbitlang/core/env` and `@json.parse` from
// `moonbitlang/core/json` - which are the toolchain rather than mooncakes
// imports, so the wall clock and the JSON parser cost two lines of
// `src/tesseract/moon.pkg`. The GUI in `cmd/gui` is the one exception: it needs
// a window, so it depends on proton. See README.mbt.md for what that means for
// the CLI.

name = "riantr/tesseract"

version = "0.1.4"

// The file with the real content. `README.md` is a symlink to this one, so
// naming the real file here states it rather than relying on every consumer
// having followed the link.

readme = "README.mbt.md"

// Where the source lives. `moon publish` warns
// "'repository' field is not set or empty in module manifest" without it, and
// the registry entry is the only place a reader can get from the package back
// to the code. 0.1.0 was published before this line existed.

repository = "https://github.com/riantr/tesseract"

license = "Apache-2.0"

keywords = [ "sudoku", "database", "key-value", "lattice", "4d" ]

preferred_target = "wasm"

description = "Tiny multi-key JSON value database over a 4D sudoku lattice (1..215 cells per axis, 81 by default), with a SQL surface and sudoku digit constraints."

import {
  "moonbit-community/proton@0.5.1",
  "moonbit-community/proton_contract@0.5.1",
  "moonbit-community/sqlite3@0.2.3",
  "moonbitlang/async@0.22.5",
  "moonbitlang/x@0.5.6",
  "riantr/moonbit_doubleML@0.164.17",
}
