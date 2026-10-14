// Tesseract, migrated to MoonBit at 4 dimensions.
//
// The core library in this toolchain carries no clock, no file I/O and no stdin
// reader, so `src/tesseract` and `cmd/main` implement everything they need
// rather than pulling it in, and stay dependency-free. The GUI in `cmd/gui`
// is the one exception: it needs a window, so it depends on proton. See
// README.mbt.md for what that means for the CLI.

name = "riantr/tesseract"

version = "0.1.0"

// The file with the real content. `README.md` exists but is empty, so leaving
// this field pointing at it would publish a blank README to mooncakes.io.

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "sudoku", "database", "key-value", "lattice", "4d" ]

preferred_target = "wasm"

description = "Tiny multi-key JSON value database over a 3x3x3x3 sudoku lattice (81 cells), with a SQL surface and sudoku digit constraints."

import {
  "moonbit-community/proton@0.3.4",
  "moonbit-community/proton_contract@0.3.4",
  "moonbit-community/sqlite3@0.2.3",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "riantr/moonbit_doubleML@0.113.0",
}
