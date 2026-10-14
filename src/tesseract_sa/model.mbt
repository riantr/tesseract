///|
/// What one static-analysis run reported.
///
/// The model is shaped by what `riantr/moonbit_static_analysis` actually
/// prints, not by what a static analyser "should" print. Two of its output
/// choices constrain this deliberately:
///
/// * It withholds the findings from files its frontend could not read, and
///   says so in `NOTPARSE`. Those are **not** defects, so there is no field
///   here for them to land in. `unparsed` records why the run understood less
///   than it scanned, which is the number a reader has to see first.
/// * It prints at most three example paths per unparsed reason, and at most a
///   fixed number of findings per file. So `FileResult::shown` and
///   `UnparsedGroup::examples` are lengths, not totals, and a reader can tell
///   a truncated list from a complete one. Storing 6315 withheld findings as
///   if they were 6311 problems would be the exact misreading the tool's own
///   documentation warns against.
///
/// The count that describes the code is `actionable`. The count that describes
/// the run is `parsed / files`.

///|
/// What happened to one file.
///
/// `Partial` is new in analyzer 0.4.0 and is the reason this is an enum rather
/// than a Bool: a file can be read up to its first `struct` or `const` and no
/// further, and reporting that as either "clean" or "found" would be a claim
/// the tool never made.
pub enum FileOutcome {
  /// Read end to end, nothing to report.
  Clean
  /// Read up to the first construct outside the analyzed subset; the rest of
  /// the file was not looked at.
  Partial
  /// Read end to end, with `defects` defects and `notices` notices.
  Found
} derive(Eq, Debug)

///|
pub extend FileOutcome with Debug::{to_repr}

///|
pub extend FileOutcome with Eq::{not_equal, equal}

///|
/// The outcome for a file the analyzer read with nothing to report.
pub fn FileOutcome::clean() -> FileOutcome {
  Clean
}

///|
/// The outcome for a file the analyzer only read part of.
pub fn FileOutcome::partial() -> FileOutcome {
  Partial
}

///|
/// The outcome for a file the analyzer read with something to report.
pub fn FileOutcome::found() -> FileOutcome {
  Found
}

///|
/// One file, as the analyzer reported it.
///
/// 0.4.0 splits a file's findings into `defects` (things it believes are wrong)
/// and `notices` (constructs it declined to analyze). Both are stored because
/// the tool prints both and a store that kept only one would rename the other.
///
/// `defects` and `notices` are **not** split per rendered finding line: the
/// tool prints the two counts on the file header and does not label the
/// individual lines, so the store does not invent a class for them. A notice
/// shows up as a `ParseError` family; that is how the tool reports one.
pub struct FileResult {
  /// The file kind the tool reported: `.mbti`, `.mbt`, `.mbt.md`, `.mbtp`.
  kind : String
  /// Path as printed, which is absolute.
  path : String
  outcome : FileOutcome
  /// Findings the analyzer believes are defects.
  defects : Int32
  /// Findings that report constructs outside the analyzed subset.
  notices : Int32
  /// How many finding lines were actually rendered. Less than the header's
  /// total means the stored list is a sample, not the whole set.
  shown : Int32
  /// For a `Partial` file, the last line that was read. 0 otherwise.
  read_up_to : Int32
  /// For a `Partial` file, how many lines after `read_up_to` were not shown.
  /// 0 otherwise.
  not_shown : Int32
} derive(Debug)

///|
pub extend FileResult with Debug::{to_repr}

///|
/// One `BYKIND` row: the per-file-kind rollup 0.4.0 prints.
pub struct ByKind {
  kind : String
  files : Int32
  parsed : Int32
  defects : Int32
  notices : Int32
} derive(Debug)

///|
pub extend ByKind with Debug::{to_repr}

///|
/// One rendered finding.
pub struct Finding {
  /// The file the `FOUND` line above it named.
  path : String
  line : Int32
  column : Int32
  /// `error`, `warning` or `hint`.
  severity : String
  /// The finding family, e.g. `UndefinedName`.
  family : String
  /// Which lenses saw it, e.g. `walk+types`.
  lenses : String
  message : String
} derive(Debug)

///|
pub extend Finding with Debug::{to_repr}

///|
/// One reason why a group of files could not be read.
pub struct UnparsedGroup {
  reason : String
  /// How many files failed for this reason.
  count : Int32
  /// Example paths, at most three. The tool prints at most three, so this is a
  /// sample and must not be read as the full list.
  examples : Array[String]
} derive(Debug)

///|
pub extend UnparsedGroup with Debug::{to_repr}

///|
/// One complete scan.
///
/// Two analyzer versions are represented, because the database accumulates
/// runs and a scan from 0.3.5 and one from 0.4.0 can sit in the same file. The
/// counters 0.4.0 added — `notices`, `unreliable` and `partial_files` — are 0
/// for a 0.3.5 run, which is exactly what that version reported.
///
/// The count that describes the code is `actionable`. `notices` are constructs
/// the analyzer declined to look at, `unreliable` are findings it produced from
/// a partial read, and `withheld` are findings on files it could not read at
/// all. None of the three is a defect. On this project's scan every actionable
/// defect sits on a file that was only read part of, and the three files read
/// end to end carry `defects=0`.
pub struct ScanReport {
  /// The target as given on the command line.
  target : String
  /// The directory the scan rooted at.
  root : String
  /// Files the scan walked.
  files : Int32
  /// Files it read end to end.
  parsed : Int32
  /// As printed, e.g. `30.7` — kept as text so the store records what was
  /// reported rather than a recomputation that could disagree.
  parsed_pct : String
  /// As the tool counts them, read only up to a first parse error — which
  /// includes the files it printed no header for at all. 0 before 0.4.0.
  partial_files : Int32
  /// The only count that describes the code.
  actionable : Int32
  /// Constructs outside the analyzed subset. Not defects.
  notices : Int32
  /// Findings from partial reads, which the tool rates unreliable. Not defects.
  unreliable : Int32
  /// Findings on files the analyzer could not read at all. Not defects.
  withheld : Int32
  /// As printed. 0.4.0 labels this line
  /// `(actionable+notices+unreliable+withheld = total)`, and on this project's
  /// scan that identity does not hold — 4 + 67 + 5122 + 1487 is 6680 against a
  /// total of 5193. The sum that does hold omits `withheld`, so `total` covers
  /// findings on files the analyzer read at least part of. The number is
  /// recorded as printed rather than recomputed, because it is the tool's
  /// figure to be right or wrong about, not this store's.
  total : Int32
  file_results : Array[FileResult]
  findings : Array[Finding]
  unparsed : Array[UnparsedGroup]
  /// The per-file-kind rollup; empty before 0.4.0.
  by_kind : Array[ByKind]
} derive(Debug)

///|
pub extend ScanReport with Debug::{to_repr}

///|
/// Constructors.
///
/// Every type here has immutable fields, and an immutable struct cannot be
/// built from outside the package that declares it - only in-package code can
/// call `Type::{}`. A function is also the better shape for a type with a
/// fixed field order, since the argument list is self-documenting where a
/// struct literal is positional.

///|
pub fn FileResult::new(
  kind : String,
  path : String,
  outcome : FileOutcome,
  defects : Int32,
  notices : Int32,
  shown : Int32,
  read_up_to : Int32,
  not_shown : Int32,
) -> FileResult {
  { kind, path, outcome, defects, notices, shown, read_up_to, not_shown, }
}

///|
/// One stored run, as listed by `list_runs`: the summary counts without the
/// per-file rows.
///
/// It is deliberately not a `ScanReport` with empty arrays. A `ScanReport`
/// claims to be the whole run, and handing one back with three empty arrays
/// would make a caller's `file_results.length()` read as "this scan covered no
/// files" rather than "this listing does not carry file rows".
pub struct RunSummary {
  id : Int32
  target : String
  root : String
  files : Int32
  parsed : Int32
  parsed_pct : String
  partial_files : Int32
  actionable : Int32
  notices : Int32
  unreliable : Int32
  withheld : Int32
  total : Int32
} derive(Debug)

///|
pub extend RunSummary with Debug::{to_repr}

///|

///|
pub fn RunSummary::new(
  id : Int32,
  target : String,
  root : String,
  files : Int32,
  parsed : Int32,
  parsed_pct : String,
  partial_files : Int32,
  actionable : Int32,
  notices : Int32,
  unreliable : Int32,
  withheld : Int32,
  total : Int32,
) -> RunSummary {
  {
    id,
    target,
    root,
    files,
    parsed,
    parsed_pct,
    partial_files,
    actionable,
    notices,
    unreliable,
    withheld,
    total,
  }
}

///|
pub fn Finding::new(
  path : String,
  line : Int32,
  column : Int32,
  severity : String,
  family : String,
  lenses : String,
  message : String,
) -> Finding {
  { path, line, column, severity, family, lenses, message, }
}

///|
pub fn UnparsedGroup::new(
  reason : String,
  count : Int32,
  examples : Array[String],
) -> UnparsedGroup {
  { reason, count, examples, }
}

///|
pub fn ByKind::new(
  kind : String,
  files : Int32,
  parsed : Int32,
  defects : Int32,
  notices : Int32,
) -> ByKind {
  { kind, files, parsed, defects, notices, }
}

///|
pub fn ScanReport::new(
  target : String,
  root : String,
  files : Int32,
  parsed : Int32,
  parsed_pct : String,
  partial_files : Int32,
  actionable : Int32,
  notices : Int32,
  unreliable : Int32,
  withheld : Int32,
  total : Int32,
  file_results : Array[FileResult],
  findings : Array[Finding],
  unparsed : Array[UnparsedGroup],
  by_kind : Array[ByKind],
) -> ScanReport {
  {
    target,
    root,
    files,
    parsed,
    parsed_pct,
    partial_files,
    actionable,
    notices,
    unreliable,
    withheld,
    total,
    file_results,
    findings,
    unparsed,
    by_kind,
  }
}
