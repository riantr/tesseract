// A probe of the published tesseract package's checkpoint format contract.
//
// This is a **nested module**: it has its own `moon.mod`, so the parent
// module's build never sees it and it can never be published. It depends on
// the **published** `riantr/tesseract@0.1.13` — the same way `qa/fuzz` does —
// so what it measures is the surface a consumer actually gets, not the surface
// sitting in the working tree.
//
// The point of the probe is to answer three questions about the durable
// memory's checkpoint file with answers that were *observed*, not assumed:
//
// - does a file this build writes come back out of this build's reader?
// - what does the reader do with a file whose header it does not understand?
// - what are the format's constants, byte for byte?

name = "tesseract_qa_contract_probe"

version = "0.1.0"

description = "A probe of the published tesseract package's checkpoint format contract."

import {
  "riantr/tesseract@0.1.13",
  "moonbit-community/sqlite3@0.2.3",
  "moonbitlang/x@0.5.6",
}
