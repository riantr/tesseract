///|
/// The command layer over a real memory.
///
/// The layer is the seam between the memory and the person at the keyboard:
/// it turns text into a command, and a command into a change to a store. A
/// test that only checked the parsing would not catch a command that ran and
/// did the wrong thing to the store, so these go all the way through to the
/// memory and back.
///
/// The clock is manual, so every boundary here is a number rather than a
/// race.

///|
/// The options and the commands of a session.
fn session(
  argv : Array[String],
) -> (@tesseract_memory_cli.Options, Array[String]) {
  @tesseract_memory_cli.parse_session(argv)
}

///|
/// The usage a command is run under.
///
/// The layer prints the usage when a command is not one it knows, so a test
/// that runs a command needs one to hand it. This one is empty on purpose:
/// what it says is not what these tests are about.
fn usage() -> @tesseract_memory_cli.Usage {
  @tesseract_memory_cli.usage("", [], [])
}

///|
/// A session's options build the store the commands then write to.
///
/// The options are not a description of the store: they are the store's
/// configuration. A command that wrote into a store built from different
/// options would be a command doing the wrong thing in a way no parsing test
/// would ever see.
test "a session's options build the store the commands then write to" {
  let (options, commands) = session([
    "--capacity", "10", "--scope", "work", "put a hello",
  ])
  assert_eq(options.capacity, 10)
  assert_eq(options.scope_name, "work")
  assert_eq(commands.length(), 1)
  // The options become the store's configuration.
  let m = @tesseract_memory.new_memory_with_clock(
    options.config(),
    @tesseract_memory.memory_clock_manual(0L),
  )
  let scope = m.scope(options.scope_name)
  ignore(@tesseract_memory_cli.run_command(m, scope, "put a hello", usage()))
  assert_eq(m.scope("work").get("a"), Some("hello"))
  // And it wrote where the options said, not where the command started.
  assert_eq(m.scope("default").get("a"), None)
}

///|
/// The layer reads a number the way the core reads it.
///
/// The value of an option is read with the core's own integer parser, so the
/// two agree on what an integer is — and on what is not one. A layer that
/// parsed numbers its own way would answer a value the core cannot read
/// differently from the core, and the answer would be a capacity nobody
/// asked for.
test "the layer reads a number the way the core reads it" {
  assert_eq(@tesseract.parse_int("12"), Some(12))
  assert_eq(@tesseract.parse_int("twelve"), None)
  let (good, _) = session(["--capacity", "12"])
  assert_eq(good.capacity, 12)
  // A value the core cannot read leaves the option where it was.
  let (bad, _) = session(["--capacity", "twelve"])
  assert_eq(bad.capacity, @tesseract_memory_cli.default_options().capacity)
}

///|
/// A command is split into its words on whitespace, however much of it there
/// is.
///
/// The layer splits the command itself, and a binary that has a command of
/// its own needs the same split — so the split is public, and a binary that
/// added a command would not have to guess where the words begin.
test "a command's words are split on whitespace, however many there are" {
  assert_eq(@tesseract_memory_cli.words_of("  put   a  hello "), [
    "put", "a", "hello",
  ])
  assert_eq(@tesseract_memory_cli.words_of("put"), ["put"])
  assert_eq(@tesseract_memory_cli.words_of("   "), [])
}

///|
/// The tour is the one command that writes a handful of entries into the
/// store it is given.
///
/// A binary whose store is a file has to know the tour is coming, because the
/// tour leaves entries behind in it. So the layer says which command is the
/// tour, and the binary asks.
test "the tour is named, and nothing else is" {
  assert_true(@tesseract_memory_cli.is_demo("demo"))
  assert_true(@tesseract_memory_cli.is_demo("  demo "))
  assert_false(@tesseract_memory_cli.is_demo("put a hello"))
  assert_false(@tesseract_memory_cli.is_demo(""))
}
