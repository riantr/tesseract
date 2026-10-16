///|
/// Where a timestamp comes from.
///
/// The C# original stamped every log entry with `DateTime.UtcNow`. The reason
/// this port refused to was narrower than it looked: the *docstring* said
/// "MoonBit's core library exposes no wall clock", and that was true of an
/// older toolchain, not of this one. `moonbitlang/core/env` carries
/// `@env.now()` - milliseconds since the Unix epoch - implemented for native
/// (`moonbit_get_ms_since_epoch`), js (`Date.now()`) and wasm
/// (`__moonbit_time_unstable`), all returning the same unit.
///
/// So a real clock costs nothing: `core` is the toolchain, not a mooncakes
/// import, so `src/tesseract` stays dependency-free and stays multi-target.
/// What was genuinely worth preserving is the second half - calling the clock
/// inline makes every stamp a function of when the test ran, and the log output
/// stops being comparable across runs.
///
/// Hence a clock is a *value*. `Logical` keeps the old deterministic counter,
/// `System` reads the host, and `Fixed` is a frozen instant so the ISO rendering
/// can be tested against a known date without reading a real clock at all.
pub enum Clock {
  Logical
  System
  Fixed(Int64)
}

///|
/// The default clock: stamps are the logical sequence number.
///
/// The variants are not usable from another package — a blackbox test writing
/// `Clock::Logical` gets `Cannot create values of the read-only type`, and `pub`
/// on a variant is refused with `No individual visibility for enum constructor`.
/// So the three ways to make one are functions.
pub fn logical_clock() -> Clock {
  Logical
}

///|
/// A clock reading the host's wall clock.
pub fn system_clock() -> Clock {
  System
}

///|
/// A clock frozen at `ms` milliseconds since the Unix epoch.
///
/// For tests that need to assert an exact stamp. `Fixed` and `System` share one
/// formatting path, so a passing case for this is evidence about what `System`
/// prints rather than a second implementation that happens to agree.
pub fn fixed_clock(ms : Int64) -> Clock {
  Fixed(ms)
}

///|
/// The stamp for entry number `seq`, as printed and stored.
///
/// The logger owns the sequence number and always did; the clock only decides
/// what kind of stamp that number becomes. `Logical` renders it `#7`, which is
/// what keeps log output byte-comparable between two runs of the same program.
pub fn Clock::stamp(self : Clock, seq : Int32) -> String {
  match self {
    Logical => "#" + seq.to_string()
    System => iso8601_ms(now_ms())
    Fixed(ms) => iso8601_ms(ms)
  }
}

///|
/// The stamp stored on a cell, which is data rather than a label.
///
/// The difference from `stamp` is the `#` and nothing else, and it is worth
/// keeping: a log line's stamp is read by a person off a console, while a cell
/// stamp goes into `.tsr`, `.md` and `.sql` and comes back out of an import
/// unchanged. Under `Logical` this stays the bare sequence number, which is what
/// every `.tsr` written so far contains.
pub fn Clock::cell_stamp(self : Clock, seq : Int32) -> String {
  match self {
    Logical => seq.to_string()
    System => iso8601_ms(now_ms())
    Fixed(ms) => iso8601_ms(ms)
  }
}

///|
/// The host clock, as a signed count of milliseconds since the Unix epoch.
///
/// `UInt64` is `Int64`'s bit pattern with a different literal suffix, so there
/// is no numeric conversion between them - `(x : Int64)` is a type error and
/// `Int64::from_uint64` does not exist. `reinterpret_as_int64` is the supported
/// spelling (the older `to_int64` still compiles but is deprecated). A host
/// clock past `Int64::MAX` would reinterpret negative; that is year 292
/// million, which no epoch-millisecond reading will reach.
pub fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// ISO-8601 in UTC with milliseconds, `2026-10-16T19:45:00.123Z`.
///
/// Written out here rather than taken from `moonbitlang/x/time`, because `x` is
/// an external dependency and the zero-dependency core is a deliberate claim
/// worth more than the import. The calendar arithmetic is Howard Hinnant's
/// `civil_from_days`, which is branch-free apart from the era adjustment and
/// handles the proleptic Gregorian calendar for the whole `Int64` range.
pub fn iso8601_ms(ms : Int64) -> String {
  let day_ms = 86400000L
  let days = floor_div(ms, day_ms)
  let tod = ms - days * day_ms
  let civil = civil_from_days(days)
  let seconds = tod / 1000L
  let b = StringBuilder::StringBuilder()
  b.write_string(pad_number(civil.year, 4))
  b.write_char('-')
  b.write_string(pad_number(civil.month, 2))
  b.write_char('-')
  b.write_string(pad_number(civil.day, 2))
  b.write_char('T')
  b.write_string(pad_number(seconds / 3600L, 2))
  b.write_char(':')
  b.write_string(pad_number(seconds / 60L % 60L, 2))
  b.write_char(':')
  b.write_string(pad_number(seconds % 60L, 2))
  b.write_char('.')
  b.write_string(pad_number(tod % 1000L, 3))
  b.write_char('Z')
  b.to_string()
}

///|
/// Floor division, so a timestamp before the epoch splits into a negative day
/// count and a positive time of day.
///
/// MoonBit truncates integer division toward zero, like C, so `-1 / 86400000`
/// is `0` and `-1 % 86400000` is `-1`. Left alone that renders the day before
/// the epoch as day 0 at 23:59:59.999, which is a different instant.
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  let r = a % b
  if r != 0L && (if r < 0L { b > 0L } else { b < 0L }) {
    q - 1L
  } else {
    q
  }
}

///|
/// One calendar date in the proleptic Gregorian calendar.
pub struct CivilDate {
  year : Int64
  month : Int64
  day : Int64
}

///|
/// Days since 1970-01-01 to a calendar date.
///
/// The `719468` offset moves the year to 0000-03-01, which puts the leap day at
/// the end of the era year and makes the rest of the conversion a pair of
/// divisions. `era` is floor-divided by hand for the same negative-value reason
/// as `floor_div` above.
fn civil_from_days(z0 : Int64) -> CivilDate {
  let z = z0 + 719468L
  let era = floor_div(z, 146097L)
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = mp + (if mp < 10L { 3L } else { -9L })
  let year = y + (if month <= 2L { 1L } else { 0L })
  { year, month, day, }
}

///|
/// Zero-padded decimal, so `iso8601_ms` prints `007` and not `7`.
///
/// Left-pads with zeroes to at least `width` digits. A value wider than `width`
/// is written in full rather than truncated - a five-digit year is a rendering
/// bug, not something to hide by dropping digits.
pub fn pad_number(v : Int64, width : Int32) -> String {
  let s = v.to_string()
  if s.length() >= width {
    return s
  }
  let b = StringBuilder::StringBuilder()
  let mut i = s.length()
  while i < width {
    b.write_char('0')
    i = i + 1
  }
  b.write_string(s)
  b.to_string()
}
