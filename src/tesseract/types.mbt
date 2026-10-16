///|
/// Record and result types, carried over from the C# model and widened to the
/// 4D lattice.
///
/// A record keeps `position` (1..total) and a `digit` (0, or 1..side). The
/// digit is what turns a plain ring buffer into a sudoku store, since two
/// records sharing an axis-parallel line may not carry the same digit.
///
/// Positions and digits are `Int64`, and the measured reason is narrower than
/// it first looks. What this toolchain actually lacks is a direct `Int64 ->
/// Int32` conversion (`Int64::to_int32` does not compile) and any `Int32 -> Int`
/// conversion (`Int32::to_int` does not compile either), while `Array` is indexed
/// by `Int`. So `Int32` is a dead end in both directions from here: it cannot be
/// reached from the `Int64` index arithmetic, and it cannot address storage. An
/// earlier version of this comment claimed there was no conversion between
/// `Int32` and either width at all; that was wrong - `Int64::to_int` and
/// `Int32::to_int64` both exist - and it is the `Int32`-specific gap that
/// matters.

///|
/// One lattice cell's contents. A cell with `key = ""` is empty.
pub struct GridCell {
  position : Int64
  key : String
  value : String
  timestamp : String
  digit : Int64
}

///|
/// An empty cell at `position`.
pub fn empty_cell(position : Int64) -> GridCell {
  { position, key: "", value: "", timestamp: "", digit: NO_DIGIT, }
}

///|
/// True when the cell holds no record.
pub fn cell_is_empty(c : GridCell) -> Bool {
  c.key == ""
}

///|
/// One row of a `SELECT` result.
///
/// `computed` holds the values of select-list items that are not columns of a
/// stored cell - an aggregate, or a scalar expression - in select-list order,
/// each with the label it was written under. `SELECT *` leaves it empty.
///
/// It is a field rather than a rendered string in `value` because
/// `SELECT digit, count(*)` is two columns, not one, and folding them into a
/// single `value` with a separator would make the result impossible to consume
/// without re-parsing the text - which is the thing a structured result exists to
/// avoid. The window's `RecordView` is a separate struct and does not carry this,
/// so nothing on the wire changes.
pub struct Computed {
  label : String
  value : String
}

///|
/// One row of a `SELECT` result.
pub struct Record {
  key : String
  value : String
  position : Int64
  coords : Coords
  timestamp : String
  digit : Int64
  computed : Array[Computed]
}

///|
/// Outcome of any operation. Mirrors the C# `DBResponse` shape.
pub struct DBResponse {
  success : Bool
  operation : String
  affected_rows : Int64
  position : Int64
  error : String
  error_code : String
  message : String
  data : Array[Record]
  total_records : Int64
}

///|
/// A successful response with no rows.
pub fn ok_response(operation : String) -> DBResponse {
  {
    success: true,
    operation,
    affected_rows: 0L,
    position: 0L,
    error: "",
    error_code: "",
    message: "操作成功",
    data: [],
    total_records: 0L,
  }
}

///|
/// A failed response carrying the C# error-code vocabulary.
pub fn err_response(code : String, error : String) -> DBResponse {
  {
    success: false,
    operation: "",
    affected_rows: 0L,
    position: 0L,
    error,
    error_code: code,
    message: "操作失败",
    data: [],
    total_records: 0L,
  }
}

///|
/// Lattice occupancy snapshot.
pub struct DBStatus {
  db_name : String
  total_cells : Int64
  current_count : Int64
  current_position : Int64
  digit_count : Int64
}

///|
/// Renders one result row as an aligned `key = value` block.
pub fn format_record(r : Record) -> String {
  let b = StringBuilder::StringBuilder()
  b.write_string("  键: ")
  b.write_string(r.key)
  b.write_string("\n  值: ")
  b.write_string(r.value)
  b.write_string("\n  位置: ")
  b.write_object(r.position)
  b.write_string("  ")
  b.write_string(format_coords(r.coords))
  if r.digit != NO_DIGIT {
    b.write_string("  数: ")
    b.write_object(r.digit)
  }
  if r.timestamp != "" {
    b.write_string("\n  时间: ")
    b.write_string(r.timestamp)
  }
  // A grouped or aggregate row carries its answer here. Without this the result
  // of `SELECT digit, count(*)` renders as a row with an empty key, which is not
  // what the query asked for and not something a reader can interpret.
  let mut i = 0
  while i < r.computed.length() {
    b.write_string("\n  ")
    b.write_string(r.computed[i].label)
    b.write_string(": ")
    b.write_string(r.computed[i].value)
    i = i + 1
  }
  b.to_string()
}

///|
/// Renders a response the way the C# view model rendered it into its output box.
pub fn format_response(r : DBResponse) -> String {
  let b = StringBuilder::StringBuilder()
  if r.success {
    b.write_string("✓ 成功\n")
    if r.operation != "" {
      b.write_string("操作: ")
      b.write_string(r.operation)
      b.write_char('\n')
    }
    if r.affected_rows > 0L {
      b.write_string("影响行数: ")
      b.write_object(r.affected_rows)
      b.write_char('\n')
    }
    if r.position > 0L {
      b.write_string("格子位置: ")
      b.write_object(r.position)
      b.write_char('\n')
    }
    // A SELECT always states its row count, including zero. The old rendering
    // only printed the block when there was something in it, so a query that
    // matched nothing printed `操作: SELECT` and nothing else - indistinguishable
    // from a statement that had not run. `WHERE key='alpha' AND key='beta'`
    // answering zero rows is exactly the answer the old parser could not give,
    // and it has to be visible that it was given.
    if r.operation == "SELECT" {
      b.write_string("\n查询结果 (")
      b.write_object(r.total_records)
      b.write_string(" 条记录):\n")
      let mut i = 0
      while i < r.data.length() {
        b.write_string(format_record(r.data[i]))
        b.write_char('\n')
        i = i + 1
      }
    } else if r.total_records > 0L {
      b.write_string("影响行数: ")
      b.write_object(r.total_records)
      b.write_char('\n')
    }
  } else {
    b.write_string("✗ 失败\n")
    b.write_string("错误: ")
    b.write_string(r.error)
    b.write_char('\n')
    if r.error_code != "" {
      b.write_string("错误代码: ")
      b.write_string(r.error_code)
      b.write_char('\n')
    }
  }
  b.to_string()
}
