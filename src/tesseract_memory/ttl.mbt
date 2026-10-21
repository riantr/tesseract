///|
/// How long an entry lives.
///
/// Two kinds, and the difference between them is the difference between a cache
/// and a memory:
///
/// - **absolute** — the deadline is fixed when the entry is written. It expires
///   five minutes after it was *recorded*, however much it is read in between.
/// - **sliding** — the deadline is pushed forward on every read. It expires
///   five minutes after it was *last used*.
///
/// The kind is per entry rather than per store, so one memory can hold a
/// sliding entry and an absolute one at the same time, and the two expire at
/// different moments.
pub enum Ttl {
  Never
  Absolute(Int64)
  Sliding(Int64)
}

///|
/// An entry that never expires.
///
/// This is not the same as a very long TTL: it is the one kind of entry the
/// `SoonestExpiry` eviction policy treats as infinitely far from expiring, and
/// so as the last thing to evict.
pub fn ttl_never() -> Ttl {
  Never
}

///|
/// An entry that lives for `ms` milliseconds from the moment it is written.
pub fn ttl_absolute(ms : Int64) -> Ttl {
  Absolute(ms)
}

///|
/// An entry that lives for `ms` milliseconds from the moment it was last read.
pub fn ttl_sliding(ms : Int64) -> Ttl {
  Sliding(ms)
}

///|
/// True for the one kind of entry that has no deadline.
pub fn Ttl::is_never(self : Ttl) -> Bool {
  match self {
    Never => true
    Absolute(_) => false
    Sliding(_) => false
  }
}

///|
/// True when a read pushes the deadline forward.
pub fn Ttl::is_sliding(self : Ttl) -> Bool {
  match self {
    Sliding(_) => true
    Never => false
    Absolute(_) => false
  }
}

///|
/// The lifetime of a TTL, in milliseconds. Zero for `Never`.
pub fn Ttl::window_ms(self : Ttl) -> Int64 {
  match self {
    Never => 0L
    Absolute(ms) => ms
    Sliding(ms) => ms
  }
}

///|
/// The deadline a TTL gives an entry written at `now_ms`.
///
/// Returns the deadline and whether a read moves it. A deadline of zero means
/// "never", which is the one value no instant can be equal to.
pub fn Ttl::deadline(self : Ttl, now_ms : Int64) -> (Int64, Bool) {
  match self {
    Never => (0L, false)
    Absolute(ms) => (now_ms + ms, false)
    Sliding(ms) => (now_ms + ms, true)
  }
}

///|
/// The name of a TTL kind, for a report.
pub fn Ttl::name(self : Ttl) -> String {
  match self {
    Never => "never"
    Absolute(ms) => "absolute " + ms.to_string() + "ms"
    Sliding(ms) => "sliding " + ms.to_string() + "ms"
  }
}
