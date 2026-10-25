///|
/// The logger's own three questions: which clock it stamps with, how many
/// entries it holds, and whether a debug entry is one of them.
///
/// None of these is asked by the library — a logger knows its own clock and
/// its own count. They are asked by whoever is *reporting* on a run, so they
/// are the logger's contract with a caller rather than with itself.
test "the logger reports the clock it stamps with, and that clock is the one in use" {
  let logger = @tesseract.new_logger("t")
  // The default is the logical counter, and it is the clock the logger says
  // it has.
  assert_eq(logger.clock_of().stamp(1), "#1")
  // Switching the clock is visible in what the logger reports, and in the
  // stamp it then writes.
  @tesseract.TesseractLogger::set_clock(
    logger,
    @tesseract.fixed_clock(1792179900123L),
  )
  assert_eq(logger.clock_of().stamp(1), "2026-10-16T19:45:00.123Z")
  @tesseract.TesseractLogger::log_info(logger, "hello", Map([]))
  assert_eq(logger.entries()[0].stamp, "2026-10-16T19:45:00.123Z")
}

///|
/// The count is the number of entries the logger holds, and a debug entry is
/// one of them.
///
/// The ring keeps the last hundred. The count is what a caller asks to know
/// whether anything was logged at all, so it has to count the debug entries
/// too: they are entries, and a run that only logged at debug level has
/// logged something.
test "the logger counts every entry, and a debug entry is one" {
  let logger = @tesseract.new_logger("t")
  assert_eq(logger.count(), 0)
  @tesseract.TesseractLogger::log_debug(logger, "starting", Map([]))
  assert_eq(logger.count(), 1)
  let entries = logger.entries()
  assert_eq(entries.length(), 1)
  // The level is read through the level's own name: the variant itself cannot
  // be written from another package, so the name is the way a caller sees it.
  assert_eq(@tesseract.level_name(entries[0].level), "DEBUG")
  assert_eq(entries[0].message, "starting")
  // The details are rendered the same way at every level, so a debug entry
  // carries them too.
  @tesseract.TesseractLogger::log_debug(
    logger,
    "with details",
    Map([("k", "v")]),
  )
  assert_eq(logger.count(), 2)
  assert_eq(logger.entries()[1].details, "k=v")
}
