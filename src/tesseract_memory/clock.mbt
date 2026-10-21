///|
/// Where a memory's time comes from.
///
/// The core store has the same problem and the same answer: a clock that reads
/// the host cannot be asserted against, because "this did not happen yet" is
/// not something a test can observe. So the memory's clock is a **value** the
/// caller chooses, and a `Manual` one only moves when the caller says so.
///
/// Every TTL boundary in this package's tests is a number rather than a race,
/// and that is the whole reason the clock is here rather than a call to
/// `@env.now()` in the middle of a comparison.
pub enum MemoryClock {
  System
  Manual(Int64)
}

///|
/// A clock reading the host's wall clock.
///
/// The default for a memory that is used for real. Expiry is then measured
/// against the same millisecond epoch the core stamps its records with.
pub fn memory_clock_system() -> MemoryClock {
  System
}

///|
/// A clock frozen at `start_ms` milliseconds since the Unix epoch.
///
/// It does not move on its own. `Memory::advance` moves it, and nothing else
/// does, so a test can put an entry exactly on the edge of its deadline and
/// step across it deliberately.
pub fn memory_clock_manual(start_ms : Int64) -> MemoryClock {
  Manual(start_ms)
}

///|
/// True for a clock that only the caller moves.
pub fn MemoryClock::is_manual(self : MemoryClock) -> Bool {
  match self {
    System => false
    Manual(_) => true
  }
}

///|
/// The current instant of a clock, in milliseconds since the Unix epoch.
pub fn MemoryClock::read(self : MemoryClock) -> Int64 {
  match self {
    System => @tesseract.now_ms()
    Manual(ms) => ms
  }
}

///|
/// The name of a clock, for a report.
pub fn MemoryClock::name(self : MemoryClock) -> String {
  match self {
    System => "system"
    Manual(_) => "manual"
  }
}
