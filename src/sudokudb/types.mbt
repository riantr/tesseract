///|
/// Record and result types, carried over from the C# model and widened to the
/// 4D lattice.
///
/// A record keeps `position` (1..81) and a `digit` (0, or 1..3). The digit is
/// new in 4D: it is what turns a plain ring buffer into a sudoku store, since
/// two records sharing an axis-parallel line may not carry the same digit.

///|
/// One lattice cell's contents. A cell with `key = ""` is empty.
pub struct GridCell {
  position : Int
  key : String
  value : String
  timestamp : String
  digit : Int
}

///|
/// An empty cell at `position`.
pub fn empty_cell(position : Int) -> GridCell {
  { position, key: "", value: "", timestamp: "", digit: NO_DIGIT, }
}

///|
/// True when the cell holds no record.
pub fn cell_is_empty(c : GridCell) -> Bool {
  c.key == ""
}

///|
/// One row of a `SELECT` result.
pub struct Record {
  key : String
  value : String
  position : Int
  coords : Coords
  timestamp : String
  digit : Int
}

///|
/// Outcome of any operation. Mirrors the C# `DBResponse` shape.
pub struct DBResponse {
  success : Bool
  operation : String
  affected_rows : Int
  position : Int
  error : String
  error_code : String
  message : String
  data : Array[Record]
  total_records : Int
}

///|
/// A successful response with no rows.
pub fn ok_response(operation : String) -> DBResponse {
  {
    success: true,
    operation,
    affected_rows: 0,
    position: 0,
    error: "",
    error_code: "",
    message: "操作成功",
    data: [],
    total_records: 0,
  }
}

///|
/// A failed response carrying the C# error-code vocabulary.
pub fn err_response(code : String, error : String) -> DBResponse {
  {
    success: false,
    operation: "",
    affected_rows: 0,
    position: 0,
    error,
    error_code: code,
    message: "操作失败",
    data: [],
    total_records: 0,
  }
}

///|
/// Lattice occupancy snapshot.
pub struct DBStatus {
  db_name : String
  total_cells : Int
  current_count : Int
  current_position : Int
  digit_count : Int
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
    if r.affected_rows > 0 {
      b.write_string("影响行数: ")
      b.write_object(r.affected_rows)
      b.write_char('\n')
    }
    if r.position > 0 {
      b.write_string("格子位置: ")
      b.write_object(r.position)
      b.write_char('\n')
    }
    if r.total_records > 0 {
      b.write_string("\n查询结果 (")
      b.write_object(r.total_records)
      b.write_string(" 条记录):\n")
      let mut i = 0
      while i < r.data.length() {
        b.write_string(format_record(r.data[i]))
        b.write_char('\n')
        i = i + 1
      }
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
