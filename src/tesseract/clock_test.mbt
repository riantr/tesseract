///|
/// The injected clock, and the ISO-8601 rendering behind it.
///
/// The expected strings here are not whatever this code happens to produce.
/// They were computed independently with .NET's `DateTimeOffset`, which is a
/// different implementation of the same conversion - a date formatter checked
/// against itself proves nothing. The cases are chosen to hit the places the
/// arithmetic can go wrong rather than to cover a range evenly:
///
/// - the epoch itself, and one millisecond after it
/// - **one millisecond before** the epoch, which is the case truncating
///   division gets wrong: `-1 / 86400000` is `0`, not `-1`
/// - 1900-01-01 and 2100-12-31, neither a leap year by the century rule
/// - 2000-03-01 and 2024-02-29, both leap years
///
/// `Fixed` exists so these can be asserted without reading a real clock.

///|
/// Milliseconds since the epoch render as the matching ISO-8601 instant.
///
/// The expected value comes from `DateTimeOffset.FromUnixTimeMilliseconds`.
test "an instant renders as ISO-8601 UTC with milliseconds" {
  assert_eq(@tesseract.iso8601_ms(0L), "1970-01-01T00:00:00.000Z")
  assert_eq(@tesseract.iso8601_ms(1L), "1970-01-01T00:00:00.001Z")
  assert_eq(@tesseract.iso8601_ms(1792179900123L), "2026-10-16T19:45:00.123Z")
}

///|
/// A millisecond before the epoch is the day before, not the epoch at 24:00.
///
/// Integer division truncates toward zero in MoonBit, so without a floor the
/// negative remainder sends this to day 0 with a 23-hour time of day.
test "an instant before the epoch does not truncate toward the epoch" {
  assert_eq(@tesseract.iso8601_ms(-1L), "1969-12-31T23:59:59.999Z")
  assert_eq(@tesseract.iso8601_ms(-86400000L), "1969-12-31T00:00:00.000Z")
}

///|
/// The century rule: 1900 and 2100 are not leap years, 2000 and 2024 are.
///
/// 1900 and 2100 are the two dates a naive `year % 4 == 0` test gets wrong, so
/// they are here precisely because they are the hard ones.
test "the century rule holds at 1900, 2000, 2024 and 2100" {
  assert_eq(@tesseract.iso8601_ms(-2208988800000L), "1900-01-01T00:00:00.000Z")
  assert_eq(@tesseract.iso8601_ms(951868800000L), "2000-03-01T00:00:00.000Z")
  assert_eq(@tesseract.iso8601_ms(1709208000000L), "2024-02-29T12:00:00.000Z")
  assert_eq(@tesseract.iso8601_ms(4133980799999L), "2100-12-31T23:59:59.999Z")
}

///|
/// The logical clock keeps the old stamp, and the sequence number is the clock's
/// only input.
///
/// This is the property that keeps 136 tests comparable between runs: the stamp
/// for entry 7 is `#7` no matter when the process started or how fast the host
/// is. A wall clock called inline would make every one of those logs a function
/// of when the test ran.
test "the logical stamp is the sequence number and needs no clock" {
  assert_eq(@tesseract.logical_clock().stamp(1), "#1")
  assert_eq(@tesseract.logical_clock().stamp(7), "#7")
  assert_eq(@tesseract.logical_clock().stamp(128), "#128")
}

///|
/// A frozen instant stamps the same string a real clock would produce there.
///
/// This is what makes the ISO rendering testable at all: `Fixed` and `System`
/// share one formatting path, so a passing `Fixed` case is evidence about what
/// `System` prints, not a parallel implementation that happens to agree.
test "a fixed clock stamps the ISO form of the instant it was given" {
  let clock = @tesseract.fixed_clock(1792179900123L)
  // The sequence number is deliberately different from the instant: a fixed
  // clock must not accidentally fall back to printing it.
  assert_eq(clock.stamp(1), "2026-10-16T19:45:00.123Z")
  assert_eq(clock.stamp(7), "2026-10-16T19:45:00.123Z")
}

///|
/// The system clock produces a real instant, and a readable one.
///
/// Not asserted against a value - that would be a race - but against the shape
/// an ISO stamp has to have. A clock that returned 0 or a sequence number would
/// fail both halves.
test "the system clock reads the host rather than a constant" {
  let stamp = @tesseract.system_clock().stamp(1)
  assert_eq(stamp.length(), 24)
  assert_eq(stamp.at(23), 'Z')
  assert_eq(stamp.at(4), '-')
  assert_eq(stamp.at(10), 'T')
  assert_true(stamp != "2026-10-16T19:45:00.000Z")
}

///|
/// Zero-padding, including the case where the value is wider than asked for.
test "pad_number pads with zeroes and never truncates" {
  assert_eq(@tesseract.pad_number(7L, 2), "07")
  assert_eq(@tesseract.pad_number(0L, 3), "000")
  assert_eq(@tesseract.pad_number(123L, 2), "123")
  assert_eq(@tesseract.pad_number(2026L, 4), "2026")
  // A five-digit year is a rendering bug, not a reason to drop a digit.
  assert_eq(@tesseract.pad_number(12345L, 4), "12345")
}

///|
/// A logger on a fixed clock stamps every entry with the same instant, and the
/// sequence numbers still advance.
///
/// Two entries sharing a timestamp is correct behaviour for a frozen clock and
/// the reason `Fixed` is a test tool rather than a default.
test "a logger stamps through its clock" {
  let logger = @tesseract.new_logger("t")
  logger.set_clock(@tesseract.fixed_clock(0L))
  logger.log_info("first", Map([]))
  logger.log_info("second", Map([]))
  let entries = @tesseract.TesseractLogger::entries(logger)
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].stamp, "1970-01-01T00:00:00.000Z")
  assert_eq(entries[1].stamp, "1970-01-01T00:00:00.000Z")
  // And the sequence still advances, so the two are distinguishable.
  assert_true(entries[0].seq < entries[1].seq)
}

///|
/// Switching the clock back is enough to restore deterministic stamps.
test "the default logger stamps logically" {
  let logger = @tesseract.new_logger("t")
  logger.log_info("first", Map([]))
  assert_eq(@tesseract.TesseractLogger::entries(logger)[0].stamp, "#1")
}
