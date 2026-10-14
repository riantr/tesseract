///|
/// Structured logging with a bounded ring, ported from the C# `TesseractLogger`.
///
/// The C# version stamped every entry with `DateTime.UtcNow` and kept the last
/// 100. MoonBit's core library exposes no wall clock, and reaching for one
/// would pin this package to a single target, so the clock is a field: the
/// default is a logical sequence number and a caller that has a real clock can
/// supply one. That also makes log output deterministic under test.

///|
/// Oldest entries past this count are dropped, matching the C# limit.
pub const MAX_LOGS : Int = 100

///|
/// Severity of a log entry.
pub enum LogLevel {
  Debug
  Info
  Warning
  Error
}

///|
/// Fixed-width severity name, as printed.
pub fn level_name(l : LogLevel) -> String {
  match l {
    Debug => "DEBUG"
    Info => "INFO"
    Warning => "WARNING"
    Error => "ERROR"
  }
}

///|
/// One recorded event.
pub struct LogEntry {
  seq : Int
  stamp : String
  level : LogLevel
  message : String
  details : String
}

///|
/// Renders `k=v` pairs in insertion-independent (sorted) order.
///
/// Sorted so that a diff of two runs lines up; a details map built in
/// different orders otherwise renders differently for identical content.
pub fn format_details(details : Map[String, String]) -> String {
  let keys : Array[String] = []
  for k, _ in details {
    keys.push(k)
  }
  let mut i = 0
  while i < keys.length() {
    let mut j = 0
    while j + 1 < keys.length() {
      if keys[j + 1] < keys[j] {
        let t = keys[j]
        keys[j] = keys[j + 1]
        keys[j + 1] = t
      }
      j = j + 1
    }
    i = i + 1
  }
  let b = StringBuilder::StringBuilder()
  let mut k = 0
  while k < keys.length() {
    if k > 0 {
      b.write_string(", ")
    }
    b.write_string(keys[k])
    b.write_char('=')
    match details.get(keys[k]) {
      Some(v) => b.write_string(v)
      None => ()
    }
    k = k + 1
  }
  b.to_string()
}

///|
/// Bounded log buffer.
pub struct TesseractLogger {
  name : String
  mut logs : Array[LogEntry]
  mut seq : Int
  mut echo : Bool
}

///|
/// A logger that starts empty and does not print.
pub fn new_logger(name : String) -> TesseractLogger {
  { name, logs: [], seq: 0, echo: false, }
}

///|
/// Turns console mirroring on or off; the CLI turns it on, tests leave it off.
pub fn TesseractLogger::set_echo(self : TesseractLogger, on : Bool) -> Unit {
  self.echo = on
}

///|
/// The current entry count.
pub fn TesseractLogger::count(self : TesseractLogger) -> Int {
  self.logs.length()
}

///|
/// A snapshot of the retained entries, oldest first.
pub fn TesseractLogger::entries(self : TesseractLogger) -> Array[LogEntry] {
  let out : Array[LogEntry] = []
  let mut i = 0
  while i < self.logs.length() {
    out.push(self.logs[i])
    i = i + 1
  }
  out
}

///| Drops every retained entry. The sequence counter keeps going, so stamps

///|
/// stay unique after a clear.
pub fn TesseractLogger::clear(self : TesseractLogger) -> Unit {
  self.logs = []
}

///|
/// Appends one entry, trimming the oldest once the ring is full.
pub fn TesseractLogger::add(
  self : TesseractLogger,
  level : LogLevel,
  message : String,
  details : String,
) -> Unit {
  self.seq = self.seq + 1
  let entry = {
    seq: self.seq,
    stamp: "#" + self.seq.to_string(),
    level,
    message,
    details,
  }
  self.logs.push(entry)
  if self.logs.length() > MAX_LOGS {
    let trimmed : Array[LogEntry] = []
    let mut i = 1
    while i < self.logs.length() {
      trimmed.push(self.logs[i])
      i = i + 1
    }
    self.logs = trimmed
  }
  if self.echo {
    // Diagnostics go to stderr, not stdout: the CLI documents
    // `moon run cmd/main -- .export tsr > dump.tsr`, and mirroring the log on
    // stdout meant the redirected file began with a banner and a log line -
    // which its own `import_tsr` then rejected as invalid JSON.
    eprintln("[" + entry.stamp + "] [" + level_name(level) + "] " + message)
  }
}

///|
/// Logs at DEBUG.
pub fn TesseractLogger::log_debug(
  self : TesseractLogger,
  message : String,
  details : Map[String, String],
) -> Unit {
  self.add(Debug, message, format_details(details))
}

///|
/// Logs at INFO.
pub fn TesseractLogger::log_info(
  self : TesseractLogger,
  message : String,
  details : Map[String, String],
) -> Unit {
  self.add(Info, message, format_details(details))
}

///|
/// Logs at WARNING.
pub fn TesseractLogger::log_warning(
  self : TesseractLogger,
  message : String,
  details : Map[String, String],
) -> Unit {
  self.add(Warning, message, format_details(details))
}

///|
/// Logs at ERROR.
pub fn TesseractLogger::log_error(
  self : TesseractLogger,
  message : String,
  details : Map[String, String],
) -> Unit {
  self.add(Error, message, format_details(details))
}

///|
/// Logs an operation outcome, matching the C# message wording.
pub fn TesseractLogger::log_operation(
  self : TesseractLogger,
  operation : String,
  success : Bool,
  details : Map[String, String],
) -> Unit {
  let message = if success {
    operation + " succeeded"
  } else {
    operation + " failed"
  }
  self.add(if success { Info } else { Error }, message, format_details(details))
}
