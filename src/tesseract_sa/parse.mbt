///|
/// Reading `riantr/moonbit_static_analysis`'s output back into a `ScanReport`.
///
/// ## Two formats, on purpose
///
/// The database accumulates runs, so a 0.3.5 scan and a 0.4.0 scan can sit in
/// the same file. 0.4.0 changed the line grammar substantially — it added
/// `PARTIAL` files, split a file's findings into `defects` and `notices`,
/// added `BYKIND`, and gave `PARSED` a trailing clause. `parse` accepts both,
/// because refusing the older runs would mean a database that can only ever
/// hold scans from one version.
///
/// The 0.4.0 grammar, from the tool's own `src/sa/main.mbt`:
////
/// ```text
/// TARGET\t<target>\t<root>
/// SCANNED\t<n> files under <root>
/// CLEAN\t<kind>\t<path>
/// PARTIAL\t<kind>\tdefects=<n>\tnotices=<n>\tread up to line <l>, <k> after it not shown\t<path>
/// FOUND\t<kind>\tdefects=<n>\tnotices=<n>\t<path>
/// <line>:<col> - <sev>: <message> (<family>) [<lenses>]
///   in <func> at <file>:<line>
/// ...  <k> more in this file
/// PARSED\t<parsed>/<total> files understood (<pct>%); <k> more read only up to their first parse error
/// BYKIND\t<kind>\tfiles=<n>\tparsed=<n>\tdefects=<n>\tnotices=<n>
/// NOTPARSE\t<n> files, <k> finding(s) withheld - ...
///   <n>x  <reason>
///       e.g. <path>
/// SUMMARY\tfiles=<n>\tparsed=<n>\tactionable=<n>\tnotices=<n>\tunreliable=<n>\twithheld=<n>\ttotal=<n>
/// ```
///
/// 0.3.5 differs in three places, all handled below: `FOUND` carried a bare
/// count instead of `defects=`/`notices=`, there was no `PARTIAL` or `BYKIND`,
/// and `PARSED` ended at the percentage.
///
/// ## Why the exit code is not consulted
///
/// The tool's documentation says a target it cannot locate still exits 0 and
/// prints only `ERROR\tcannot locate source for target: ...`. So the absence of
/// a `SUMMARY` line is the failure signal, and `parse` treats it as one:
/// storing a run with no `SUMMARY` would store an empty report that reads like
/// "the scan found nothing".

///|
/// The last position of `needle` in `haystack`, or `None`.
///
/// The analyzer appends `(family)` and `[lenses]` at the *end* of a finding
/// line, so those two have to be taken from the right. `tesseract` exposes
/// `index_of_ci`, which finds the first and is case-insensitive; neither is
/// what this needs.
fn last_index_of(haystack : String, needle : String) -> Int? {
  let mut i = haystack.length() - needle.length()
  while i >= 0 {
    if @tesseract.slice(haystack, i, i + needle.length()) == needle {
      return Some(i)
    }
    i = i - 1
  }
  None
}

///|
/// The text between the last `open` and the last `close`, or `None`.
fn between_last(s : String, open : String, close : String) -> String? {
  match last_index_of(s, close) {
    None => None
    Some(close_at) =>
      match last_index_of(@tesseract.slice(s, 0, close_at), open) {
        None => None
        Some(open_at) =>
          Some(@tesseract.slice(s, open_at + open.length(), close_at))
      }
  }
}

///|
/// One `L:C - sev: message (family) [lenses]` line.
fn parse_finding(line : String, path : String) -> Finding? {
  let dash = match @tesseract.index_of_ci(line, " - ") {
    None => return None
    Some(i) => i
  }
  let head = @tesseract.slice(line, 0, dash)
  let tail = @tesseract.slice(line, dash + 3, line.length())
  let colon = match @tesseract.index_of_ci(head, ":") {
    None => return None
    Some(i) => i
  }
  let line_no = match @tesseract.parse_int(@tesseract.slice(head, 0, colon)) {
    None => return None
    Some(v) => v
  }
  let col_no = match
    @tesseract.parse_int(@tesseract.slice(head, colon + 1, head.length())) {
    None => return None
    Some(v) => v
  }
  let sev_colon = match @tesseract.index_of_ci(tail, ":") {
    None => return None
    Some(i) => i
  }
  let severity = @tesseract.slice(tail, 0, sev_colon)
  let body = @tesseract.slice(tail, sev_colon + 1, tail.length())
  let family = match between_last(body, "(", ")") {
    None => return None
    Some(f) => f
  }
  let lenses = match between_last(body, "[", "]") {
    None => return None
    Some(l) => l
  }
  // The message runs up to the `(family)` the tool appends, not up to the `)`
  // that closes it: slicing at the closing paren would leave
  // "unknown name `nope` (UndefinedName" as the message.
  let close_paren = match last_index_of(body, ")") {
    None => return None
    Some(i) => i
  }
  let open_paren = match
    last_index_of(@tesseract.slice(body, 0, close_paren), "(") {
    None => return None
    Some(i) => i
  }
  let message = @tesseract.trim_ws(@tesseract.slice(body, 0, open_paren))
  Some({
    path,
    line: line_no,
    column: col_no,
    severity,
    family,
    lenses,
    message,
  })
}

///|
/// The `key=value` pairs of a `SUMMARY` or `BYKIND` line.
fn field_value(fields : Array[String], key : String) -> Int? {
  for f in fields {
    if @tesseract.starts_with(f, key + "=") {
      return @tesseract.parse_int(
        @tesseract.slice(f, key.length() + 1, f.length()),
      )
    }
  }
  None
}

///|
/// The integer at the front of `s`, or 0.
///
/// It stops at the first character that is not a digit and does not skip
/// leading spaces, so `" 27 more"` reads as 0 and not 27. Callers that slice
/// out of a `;`-separated clause have to `trim_ws` first, or a count silently
/// becomes a plausible-looking zero. There is deliberately no error return: a
/// field that is not a count is not a parse failure, it is a count of nothing,
/// and every call site here is on a shape the tool controls.
fn leading_count(s : String) -> Int {
  let digits : Array[Char] = []
  for c in s {
    if c >= '0' && c <= '9' {
      digits.push(c)
    } else {
      break
    }
  }
  if digits.length() == 0 {
    return 0
  }
  let buf = StringBuilder::StringBuilder()
  for c in digits {
    buf.write_char(c)
  }
  @tesseract.parse_int(buf.to_string()).unwrap_or(0)
}

///|
/// True for a line shaped like `<digits>x  <reason>`.
///
/// Every `reason` is free text, so the test cannot be "the line contains an
/// x". It is: a leading digit run, then the literal `x` and two spaces.
fn is_reason_line(line : String) -> Bool {
  if line.length() == 0 {
    return false
  }
  if line.at(0) < '0' || line.at(0) > '9' {
    return false
  }
  @tesseract.index_of_ci(line, "x  ") is Some(_)
}

///|
/// How far a `PARTIAL` file was read: `read up to line 63, 80 after it not
/// shown`. Returns `(0, 0)` for any other shape.
fn partial_extent(field : String) -> (Int, Int) {
  let parts = @tesseract.split(field, ",")
  if parts.length() < 2 {
    return (0, 0)
  }
  let first = @tesseract.trim_ws(parts[0])
  let second = @tesseract.trim_ws(parts[1])
  if !@tesseract.starts_with(first, "read up to line") {
    return (0, 0)
  }
  let rest = @tesseract.trim_ws(@tesseract.slice(first, 15, first.length()))
  let words = @tesseract.split(rest, " ")
  let up_to = match words.length() > 0 {
    true => leading_count(words[0])
    false => 0
  }
  let after = if @tesseract.starts_with(second, "after it not shown") {
    0
  } else {
    leading_count(second)
  }
  (up_to, after)
}

///|
/// One `CLEAN` / `PARTIAL` / `FOUND` header.
///
/// The path is always the **last** field and the kind the **first**; only the
/// fields between them changed between versions. Treating the path as "field 2"
/// would, on 0.4.0's `FOUND`, store `defects=0` as the path and drop the real
/// one — a row that looks present and points nowhere.
fn parse_file_header(
  fields : Array[String],
  outcome : FileOutcome,
) -> FileResult? {
  if fields.length() < 2 {
    return None
  }
  let kind = fields[0]
  let path = fields[fields.length() - 1]
  let mut defects = 0
  let mut notices = 0
  let mut read_up_to = 0
  let mut not_shown = 0
  let mut i = 1
  while i + 1 < fields.length() {
    let f = fields[i]
    if @tesseract.starts_with(f, "defects=") {
      defects = leading_count(@tesseract.slice(f, 8, f.length()))
    } else if @tesseract.starts_with(f, "notices=") {
      notices = leading_count(@tesseract.slice(f, 8, f.length()))
    } else if @tesseract.starts_with(f, "read up to line") {
      let pair = partial_extent(f)
      read_up_to = pair.0
      not_shown = pair.1
    } else {
      // 0.3.5 wrote a bare finding count here.
      defects = leading_count(f)
    }
    i = i + 1
  }
  Some({
    kind,
    path,
    outcome,
    defects,
    notices,
    shown: 0,
    read_up_to,
    not_shown,
  })
}

///|
/// Reads one scan's output.
///
/// `Err` when the run did not produce a `SUMMARY` - which is the only reliable
/// failure signal the tool offers, since a run that cannot find its target
/// still exits 0.
pub fn parse(output : String) -> Result[ScanReport, String] {
  // `Out-File -Encoding utf8` in Windows PowerShell prefixes a BOM, and a
  // BOM left on line one would make the first tag read as `<BOM>TARGET`.
  let text = if @tesseract.starts_with(output, "\u{FEFF}") {
    @tesseract.slice(output, 1, output.length())
  } else {
    output
  }
  let lines = @tesseract.split(text, "\n")
  let mut target = ""
  let mut root = ""
  let mut scanned = 0
  let mut parsed = 0
  let mut pct = ""
  let mut partial_files = 0
  let mut actionable = 0
  let mut notices = 0
  let mut unreliable = 0
  let mut withheld = 0
  let mut total = 0
  let mut seen_summary = false
  let file_results : Array[FileResult] = []
  let findings : Array[Finding] = []
  let unparsed : Array[UnparsedGroup] = []
  let by_kind : Array[ByKind] = []
  // The file a bare finding line belongs to: the most recent file header.
  let mut current = ""
  for raw in lines {
    let line = @tesseract.trim_ws(raw)
    if line == "" {
      continue
    }
    if @tesseract.starts_with(line, "ERROR\t") {
      return Err(@tesseract.slice(line, 6, line.length()))
    }
    if @tesseract.starts_with(line, "TARGET\t") {
      // Two tab-separated fields. A comma here would be a plausible guess and
      // a wrong one: splitting on it yields a single element, `target` keeps
      // both paths joined by a tab, and `root` comes back empty - which reads
      // as "the scan had no root" rather than as a parse bug.
      let parts = @tesseract.split(@tesseract.slice(line, 7, line.length()), "\t")
      if parts.length() > 0 {
        target = parts[0]
      }
      if parts.length() > 1 {
        root = parts[1]
      }
      continue
    }
    if @tesseract.starts_with(line, "SCANNED\t") {
      scanned = leading_count(@tesseract.slice(line, 8, line.length()))
      continue
    }
    if @tesseract.starts_with(line, "BYKIND\t") {
      let f = @tesseract.split(@tesseract.slice(line, 7, line.length()), "\t")
      by_kind.push({
        kind: if f.length() > 0 {
          f[0]
        } else {
          ""
        },
        files: field_value(f, "files").unwrap_or(0),
        parsed: field_value(f, "parsed").unwrap_or(0),
        defects: field_value(f, "defects").unwrap_or(0),
        notices: field_value(f, "notices").unwrap_or(0),
      })
      continue
    }
    if @tesseract.starts_with(line, "CLEAN\t") ||
      @tesseract.starts_with(line, "FOUND\t") ||
      @tesseract.starts_with(line, "PARTIAL\t") {
      let at = match @tesseract.index_of_ci(line, "\t") {
        None => continue
        Some(i) => i
      }
      let tag = @tesseract.slice(line, 0, at)
      let outcome = if tag == "CLEAN" {
        Clean
      } else if tag == "PARTIAL" {
        Partial
      } else {
        Found
      }
      let fields = @tesseract.split(
        @tesseract.slice(line, at + 1, line.length()),
        "\t",
      )
      match parse_file_header(fields, outcome) {
        None => ()
        Some(header) => {
          current = header.path
          file_results.push(header)
        }
      }
      continue
    }
    if @tesseract.starts_with(line, "PARSED\t") {
      let parts = @tesseract.split(
        @tesseract.slice(line, 7, line.length()),
        " files understood (",
      )
      if parts.length() > 0 {
        let nums = @tesseract.split(parts[0], "/")
        if nums.length() > 0 {
          parsed = leading_count(nums[0])
        }
      }
      if parts.length() > 1 {
        // The percentage is whatever sits between the `(` that opens it and the
        // `)` that closes it. 0.4.0 appends `); <n> more read only up to their
        // first parse error` and 0.3.5 ends at the `)` - reading a fixed number
        // of characters off the end, or splitting on `);`, leaves a trailing
        // `%` (0.4.0) or a whole `%)` (0.3.5) in the stored string. Neither is
        // a number anybody would notice is wrong.
        let rest = parts[1]
        let close = @tesseract.index_of_ci(rest, ")")
        let inner = match close {
          Some(i) => @tesseract.slice(rest, 0, i)
          None => rest
        }
        let num = @tesseract.split(inner, "%")
        pct = @tesseract.trim_ws(num[0])
        // The partial-file count only exists from 0.4.0 on.
        match @tesseract.index_of_ci(rest, ";") {
          Some(i) =>
            // `leading_count` stops at the first non-digit, so the space after
            // the semicolon has to go first — left in, it yields 0, which is
            // indistinguishable from a run that really read no partial files.
            partial_files = leading_count(
              @tesseract.trim_ws(@tesseract.slice(rest, i + 1, rest.length())),
            )
          None => ()
        }
      }
      continue
    }
    if @tesseract.starts_with(line, "SUMMARY\t") {
      seen_summary = true
      let fields = @tesseract.split(
        @tesseract.slice(line, 8, line.length()),
        "\t",
      )
      scanned = field_value(fields, "files").unwrap_or(scanned)
      parsed = field_value(fields, "parsed").unwrap_or(parsed)
      actionable = field_value(fields, "actionable").unwrap_or(0)
      notices = field_value(fields, "notices").unwrap_or(0)
      unreliable = field_value(fields, "unreliable").unwrap_or(0)
      withheld = field_value(fields, "withheld").unwrap_or(0)
      total = field_value(fields, "total").unwrap_or(0)
      continue
    }
    // Matched by shape rather than by indentation: the tool indents these
    // lines and has changed that indent between versions, so a check on the
    // leading spaces would quietly stop matching and every unparsed group
    // would go missing - which reads as "nothing was unparsed" rather than as
    // a parse failure.
    if is_reason_line(line) {
      let at = match @tesseract.index_of_ci(line, "x  ") {
        None => continue
        Some(i) => i
      }
      let count = leading_count(@tesseract.slice(line, 0, at))
      let reason = @tesseract.trim_ws(
        @tesseract.slice(line, at + 3, line.length()),
      )
      unparsed.push({ reason, count, examples: [], })
      continue
    }
    if @tesseract.starts_with(line, "e.g. ") {
      if unparsed.length() > 0 {
        let last = unparsed.length() - 1
        unparsed[last].examples.push(@tesseract.slice(line, 5, line.length()))
      }
      continue
    }
    if @tesseract.starts_with(line, "... ") {
      // `...  <k> more in this file` - the tool truncated this file's list.
      continue
    }
    if @tesseract.starts_with(line, "in ") {
      // A virtual-stack frame under a finding: `  in main() at main.mbt:87`.
      //
      // Redundant with `parse_finding`'s own requirement of a ` - ` followed by
      // a `line:column` head, which such a line cannot satisfy. It is kept as
      // a guard rather than as a claim of coverage: deleting it was measured as
      // an *equivalent mutant* against the captured scan - the suite stays
      // green either way, because the guard is not what stops these lines.
      // If `parse_finding` is ever loosened, this is the line that keeps the
      // frames out.
      continue
    }
    match parse_finding(line, current) {
      Some(f) => {
        findings.push(f)
        if file_results.length() > 0 {
          // The record is immutable, so the running count is written back by
          // replacing the entry rather than by mutating a field.
          let last = file_results.length() - 1
          let prev = file_results[last]
          file_results[last] = {
            kind: prev.kind,
            path: prev.path,
            outcome: prev.outcome,
            defects: prev.defects,
            notices: prev.notices,
            shown: prev.shown + 1,
            read_up_to: prev.read_up_to,
            not_shown: prev.not_shown,
          }
        }
      }
      None => ()
    }
  }
  if !seen_summary {
    return Err(
      "no SUMMARY line: the scan did not complete (it prints ERROR and still exits 0)",
    )
  }
  Ok({
    target,
    root,
    files: scanned,
    parsed,
    parsed_pct: pct,
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
  })
}
