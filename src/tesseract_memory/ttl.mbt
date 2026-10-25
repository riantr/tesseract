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
/// True when this is a lifetime a memory can honour.
///
/// A lifetime in the past is not a lifetime: an entry written with one is
/// already dead when it is written, so the store refuses the write rather
/// than accepting one that does nothing.
///
/// A lifetime of **zero** is refused for the same reason, and for one more:
/// an entry whose deadline is the moment it was written is dead on arrival,
/// and a deadline of zero is also the deadline the store uses for an entry
/// that never expires. A store that told those two apart by the deadline
/// would give the zero-lifetime entry the other one's meaning — it would
/// live forever. So the shortest lifetime there is one millisecond, and
/// `ttl_never` is how a caller says "no deadline".
pub fn Ttl::is_valid(self : Ttl) -> Bool {
  // `Never` is the one kind with no lifetime at all, and it is valid. Every
  // other kind has a lifetime, and it has to be a positive one.
  self.is_never() || self.window_ms() > 0L
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
/// The largest instant an `Int64` can hold.
///
/// An instant is a moment in time, and a deadline and a clock are both
/// instants. The bound is here because the arithmetic on them would otherwise
/// wrap round silently, and a moment in the past is a moment the store would
/// then treat as "already expired".
const MAX_INSTANT : Int64 = 9223372036854775807L

///|
/// An instant `ms` after `now_ms`, as late as the store can say.
///
/// The sum of two instants that does not fit in an `Int64` would wrap round
/// into the past, and a deadline in the past is an entry that is already
/// dead. So the sum **saturates**: the entry lives as long as the store can
/// express, which is the closest true thing to say about a lifetime of nine
/// hundred million years.
fn instant_after(now_ms : Int64, ms : Int64) -> Int64 {
  if ms > 0L && now_ms > MAX_INSTANT - ms {
    MAX_INSTANT
  } else {
    now_ms + ms
  }
}

///|
/// The deadline a TTL gives an entry written at `now_ms`.
///
/// Returns the deadline and whether a read moves it. A `Never` has no
/// deadline and its deadline is zero — and a zero deadline on an entry *with*
/// a window is an ordinary deadline, because whether an entry expires is
/// decided by its window.
pub fn Ttl::deadline(self : Ttl, now_ms : Int64) -> (Int64, Bool) {
  let deadline = match self {
    Never => 0L
    Absolute(ms) => instant_after(now_ms, ms)
    Sliding(ms) => instant_after(now_ms, ms)
  }
  // The second value says whether a read moves the deadline, and that is
  // exactly what "sliding" means. Asking the predicate rather than repeating
  // the case keeps one place deciding which lifetimes slide, so the predicate
  // and the deadline cannot come to disagree.
  (deadline, self.is_sliding())
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
