///|
/// Recording a real dataset into a Tesseract lattice, and reading it back.
///
/// The question this package exists to answer is narrow: *given data that is
/// actually shaped like a dataset, does this store record it?* Three toy
/// strings would not answer it. A lattice filled by a seeded data-generating
/// process is 81 rows of correlated Gaussian covariates plus two vectors of
/// double-precision outcomes, which is where a store's precision either shows
/// up or does not.
///
/// Nothing here is special to Tesseract's rules - no cell carries a digit, so
/// the sudoku constraint never fires and the recording is a pure store
/// question. The constraint layer gets its own tests in `src/tesseract`.
///
/// The generated data comes from `riantr/moonbit_doubleML`, which ports the
/// upstream `doubleml` DGPs to MoonBit. They are seeded, so every assertion
/// below is about fixed numbers rather than about a run that happened to pass.

///|
/// One row of a dataset, before it is written into the lattice.
pub struct Observation {
  /// Row index in the source dataset, `0`-based.
  index : Int32
  /// Treatment value `d`.
  d : Double
  /// Outcome value `y`.
  y : Double
  /// Covariate row `x`, of length `dim_x`.
  x : Array[Double]
}

///|
/// A generated dataset and the parameter it was built from.
pub struct Dataset {
  /// Which DGP produced it, for the report and for failure messages.
  source : String
  /// The causal parameter the DGP was built around.
  theta : Double
  /// Number of covariate columns per row.
  dim_x : Int32
  /// The rows, in source order.
  observations : Array[Observation]
}

///|
/// What one recording pass put into the lattice.
///
/// `rejected` is not an error path that should normally be zero - it is the
/// count the store refused, so that "recorded 81 of 93" and "recorded 93" stay
/// two different answers.
pub struct RecordReport {
  /// Rows the store accepted.
  recorded : Int32
  /// Rows the store refused.
  rejected : Int32
  /// Rows the dataset held.
  offered : Int32
  /// The first cell the pass could not use, or 0 when every row was placed.
  ///
  /// A position, so `Int64` like every other position in the store - a cell
  /// number that had to be narrowed to fit the old `Int32` report was already
  /// the wrong type for a side big enough to matter.
  stopped_at : Int64
} derive(Eq, Debug)

///|
pub extend RecordReport with Eq::{not_equal, equal}

///|
pub extend RecordReport with Debug::{to_repr}

///|
/// The lattice's cell count, which is also this package's per-dataset ceiling.
///
/// A function rather than a constant: the cell count is `side^4`, so a `const`
/// could only ever be right for one side. Asking the store's own lattice is what
/// keeps this correct at `lattice_of(4)` instead of quietly describing a
/// 3-per-axis lattice.
pub fn cell_count(db : @tesseract.Tesseract) -> Int64 {
  @tesseract.Tesseract::lattice_of_db(db).total
}

///|
/// Builds one observation.
///
/// A constructor rather than a struct literal: `Observation`'s fields are all
/// immutable, and an immutable struct cannot be built from outside the package
/// that declares it - only in-package code can call `Observation::{}`. Handing
/// callers a function is also the better shape for a type that has a fixed
/// field order.
pub fn Observation::new(
  index : Int32,
  d : Double,
  y : Double,
  x : Array[Double],
) -> Observation {
  { index, d, y, x, }
}

///|
/// Builds a dataset.
///
/// Same reason as `Observation::new`.
pub fn Dataset::new(
  source : String,
  theta : Double,
  dim_x : Int32,
  observations : Array[Observation],
) -> Dataset {
  { source, theta, dim_x, observations, }
}

///|
/// The decimal text for `d`, or `None` when `d` is NaN or infinite.
///
/// Non-finite values are refused rather than written. `NaN` and `Infinity` are
/// not JSON numbers, so a lattice that held one would carry text no JSON parser
/// accepts - a record that is present and unreadable, which is worse than a
/// refused row because the count would still say it was stored.
///
/// Finiteness is spelled `(d - d) == 0.0` because this toolchain's core
/// library offers no `is_finite` / `is_nan`. That expression is true only for
/// finite values: NaN minus NaN is NaN, and both infinities subtract to NaN,
/// while every finite `d` cancels exactly to zero.
fn encode_number(d : Double) -> String? {
  if d - d != 0.0 {
    return None
  }
  Some(d.to_string())
}

///|
/// The JSON document for one observation.
///
/// `i` and `n` are integers; `d`, `y` and `x` are double-precision numbers
/// written at full round-trip precision. The field order is fixed so that the
/// same dataset always produces the same bytes.
pub fn encode(obs : Observation) -> String? {
  let d = match encode_number(obs.d) {
    Some(s) => s
    None => return None
  }
  let y = match encode_number(obs.y) {
    Some(s) => s
    None => return None
  }
  let xs : Array[String] = []
  for v in obs.x {
    match encode_number(v) {
      Some(s) => xs.push(s)
      None => return None
    }
  }
  Some(
    "{\"i\":" +
    obs.index.to_string() +
    ",\"d\":" +
    d +
    ",\"y\":" +
    y +
    ",\"x\":[" +
    xs.join(",") +
    "]}",
  )
}

///|
/// The double at `obj[key]`, or `None` when the key is absent or not a number.
///
/// Pattern-matched rather than read through `Json::as_number`, which this
/// toolchain deprecates in favour of exactly this form.
fn number_field(obj : Map[String, Json], key : String) -> Double? {
  match obj.get(key) {
    Some(Json::Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// The observation encoded in `value`, or `None` when it is not one.
///
/// This is the read side of the same claim `encode` makes, kept public so the
/// round trip can be exercised by anything holding a lattice, not only by the
/// tests.
pub fn decode(value : String) -> Observation? {
  let parsed = @json.parse(value) catch { _ => return None }
  let obj = match parsed {
    Json::Object(m) => m
    _ => return None
  }
  let index = match obj.get("i") {
    Some(Json::Number(n, ..)) => n.to_int()
    _ => return None
  }
  let d = match number_field(obj, "d") {
    Some(v) => v
    None => return None
  }
  let y = match number_field(obj, "y") {
    Some(v) => v
    None => return None
  }
  let xs : Array[Double] = []
  match obj.get("x") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Number(n, ..) => xs.push(n)
          _ => return None
        }
      }
    _ => return None
  }
  Some({ index, d, y, x: xs, })
}

///|
/// Writes every observation of `data` into `db`, one cell per row, in order.
///
/// Row `i` goes to cell `i + 1`. When the dataset is larger than the lattice,
/// the pass stops at the cell that would have overflowed and records how many
/// rows the store refused - it does not wrap around and overwrite the rows it
/// already wrote, because that would report success for a dataset it did not
/// actually record.
pub fn record(db : @tesseract.Tesseract, data : Dataset) -> RecordReport {
  // The lattice is the store's own, so the ceiling follows whichever side it was
  // built at rather than a cell count written into this file.
  let lat = @tesseract.Tesseract::lattice_of_db(db)
  let mut recorded = 0
  let mut rejected = 0
  let mut stopped_at = 0L
  let mut i = 0
  for obs in data.observations {
    let position = i.to_int64() + lat.first_position
    if !@tesseract.position_in_bounds(lat, position) {
      rejected = rejected + 1
      if stopped_at == 0L {
        stopped_at = position
      }
      continue
    }
    match encode(obs) {
      None => rejected = rejected + 1
      Some(value) => {
        let response = @tesseract.Tesseract::insert(
          db,
          observation_key(obs.index),
          value,
          Some(position),
          @tesseract.NO_DIGIT,
        )
        if response.success {
          recorded = recorded + 1
        } else {
          rejected = rejected + 1
          if stopped_at == 0L {
            stopped_at = position
          }
        }
      }
    }
    i = i + 1
  }
  { recorded, rejected, offered: data.observations.length(), stopped_at, }
}

///|
/// The dataset as `INSERT` statements this project's own parser accepts.
///
/// The escape hatch for a dataset the caller does not want to hand to
/// `record`: it turns generated data into text that `cmd/main` and
/// `cmd/persist` can both execute, so the same rows can be loaded through the
/// CLI, written to a `.db`, or pasted into the window.
///
/// An observation with a non-finite number contributes no statement rather than
/// a broken one, so the script stays executable.
pub fn to_sql(data : Dataset) -> String {
  let out = StringBuilder::StringBuilder()
  for obs in data.observations {
    match encode(obs) {
      None => ()
      Some(value) => {
        // The value is JSON: it contains `"` but never `'`, so the single
        // quotes this parser expects wrap it without further escaping.
        out.write_string(
          "INSERT INTO tesseract (key,value) VALUES ('" +
          observation_key(obs.index) +
          "','" +
          value +
          "');",
        )
        out.write_char('\n')
      }
    }
  }
  out.to_string()
}

///|
/// The lattice key for a dataset row.
///
/// Derived from the dataset row index rather than from the cell, so that
/// moving a row to a different cell cannot silently rename it.
pub fn observation_key(index : Int32) -> String {
  "obs_" + index.to_string()
}

///|
/// Every row the lattice currently holds, ordered by cell.
pub fn recorded(db : @tesseract.Tesseract) -> Array[@tesseract.Record] {
  @tesseract.Tesseract::select(db, "", "", None, @tesseract.no_filter(), None).data
}

///|
/// Reads a whole dataset back out of the lattice.
///
/// `None` means some row did not decode, which is a different answer from a
/// dataset that came back with the wrong numbers - the first is a broken
/// record, the second is a wrong one, and only the second is a fidelity
/// failure. The tests assert on both.
pub fn read_back(
  db : @tesseract.Tesseract,
  expected : Dataset,
) -> Array[Observation]? {
  let rows = recorded(db)
  if rows.length() != expected.observations.length() {
    return None
  }
  let out : Array[Observation] = []
  for row in rows {
    match decode(row.value) {
      Some(obs) => out.push(obs)
      None => return None
    }
  }
  Some(out)
}
