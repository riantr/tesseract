///|
/// Which entry goes when the store is full.
///
/// The names are the ones people already mean by them, and they answer
/// different questions:
///
/// - `LeastRecentlyUsed` — what nobody has touched for longest.
/// - `LeastFrequentlyUsed` — what nobody has read, however long ago.
/// - `SoonestExpiry` — what is closest to expiring anyway. An entry that never
///   expires is infinitely far from expiring, so it goes last.
/// - `OldestFirst` — what was written longest ago, regardless of use.
///
/// Every policy breaks a tie the same way: by key. A store that evicts a
/// different entry on two runs of the same program is a store nobody can test.
pub enum EvictionPolicy {
  LeastRecentlyUsed
  LeastFrequentlyUsed
  SoonestExpiry
  OldestFirst
}

///|
/// Evict the entry nobody has touched for longest.
pub fn evict_lru() -> EvictionPolicy {
  LeastRecentlyUsed
}

///|
/// Evict the entry nobody has read.
pub fn evict_lfu() -> EvictionPolicy {
  LeastFrequentlyUsed
}

///|
/// Evict the entry closest to expiring.
pub fn evict_soonest_expiry() -> EvictionPolicy {
  SoonestExpiry
}

///|
/// Evict the entry written longest ago.
pub fn evict_oldest() -> EvictionPolicy {
  OldestFirst
}

///|
/// The name of a policy, for a report.
pub fn EvictionPolicy::name(self : EvictionPolicy) -> String {
  match self {
    LeastRecentlyUsed => "lru"
    LeastFrequentlyUsed => "lfu"
    SoonestExpiry => "soonest-expiry"
    OldestFirst => "oldest"
  }
}
