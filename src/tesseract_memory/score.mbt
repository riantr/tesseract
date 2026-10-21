///|
/// The words of a text.
///
/// Two rules, and the second one is there because the first one alone would
/// make the whole thing useless on half the world's text:
///
/// - A run of ASCII letters and digits is **one** word. `hello-world` is two
///   words, `abc123` is one.
/// - A character **outside** ASCII is **one word by itself**. Chinese has no
///   spaces, so an ASCII-only tokenizer would reduce a whole sentence to
///   nothing and every Chinese document would score zero against every other
///   one. Splitting by character is crude next to a real segmenter, and it is
///   the difference between "these two Chinese sentences share the words 苹果
///   and 手机" and "these two sentences are both empty".
///
/// The text is lowercased first, so `Apple` and `apple` are the same word.
pub fn tokenize(text : String) -> Array[String] {
  let lowered = @tesseract.lower(text)
  let n = lowered.length()
  let out : Array[String] = []
  let mut start = -1
  let mut i = 0
  while i < n {
    let c = lowered.at(i).to_int()
    if is_ascii_word(c) {
      if start < 0 {
        start = i
      }
    } else if c >= 128 {
      // A wide character is a word of its own, so it is pushed on its own and
      // does not interrupt a run of ASCII.
      if start >= 0 {
        out.push(@tesseract.slice(lowered, start, i))
        start = -1
      }
      out.push(@tesseract.slice(lowered, i, i + 1))
    } else if start >= 0 {
      out.push(@tesseract.slice(lowered, start, i))
      start = -1
    }
    i = i + 1
  }
  if start >= 0 {
    out.push(@tesseract.slice(lowered, start, n))
  }
  out
}

///|
/// True for an ASCII letter or digit.
fn is_ascii_word(c : Int32) -> Bool {
  (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
}

///|
/// The distinct words of a text, in order of first appearance.
pub fn token_set(text : String) -> Array[String] {
  let out : Array[String] = []
  for token in tokenize(text) {
    if !out.contains(token) {
      out.push(token)
    }
  }
  out
}

///|
/// How alike two texts are, under one policy.
///
/// The score is in `0.0..1.0`. It is **exact** — the same two texts always
/// give the same score — because there is no model here to drift.
pub fn similarity_score(a : String, b : String, policy : Similarity) -> Double {
  match policy {
    Jaccard => jaccard(a, b)
    Cosine => cosine(a, b)
    Containment => containment(a, b)
    Structure => structure_similarity(a, b)
  }
}

///|
/// The share of the combined vocabulary that the two texts share.
///
/// Two texts with nothing in common score 0.0. Two **empty** texts also score
/// 0.0 rather than 1.0: an empty document is not alike another empty document,
/// it is the absence of anything to compare, and calling that 1.0 would make a
/// blank entry match every blank query perfectly.
pub fn jaccard(a : String, b : String) -> Double {
  let sa = token_set(a)
  let sb = token_set(b)
  if sa.length() == 0 && sb.length() == 0 {
    return 0.0
  }
  let shared = count_shared(sa, sb)
  let union = sa.length() + sb.length() - shared
  if union == 0 {
    0.0
  } else {
    shared.to_double() / union.to_double()
  }
}

///|
/// The cosine of the two token-count vectors.
///
/// A word said three times counts three times, which is what separates this
/// from Jaccard on a document that repeats itself.
pub fn cosine(a : String, b : String) -> Double {
  let ta = token_counts(a)
  let tb = token_counts(b)
  let mut dot = 0.0
  let mut norm_a = 0.0
  let mut norm_b = 0.0
  for (token, count) in ta {
    let other = count_of(tb, token)
    dot = dot + count.to_double() * other.to_double()
    norm_a = norm_a + count.to_double() * count.to_double()
  }
  for (_, count) in tb {
    norm_b = norm_b + count.to_double() * count.to_double()
  }
  if norm_a == 0.0 || norm_b == 0.0 {
    return 0.0
  }
  dot / (norm_a.sqrt() * norm_b.sqrt())
}

///|
/// How much of the **first** text the second one covers.
///
/// The first text is the query and the second is the candidate, and the
/// asymmetry is the point: a two-word query should match a long document that
/// contains both words, and a symmetric measure punishes that document for
/// being long.
pub fn containment(a : String, b : String) -> Double {
  let sa = token_set(a)
  let sb = token_set(b)
  if sa.length() == 0 {
    return 0.0
  }
  count_shared(sa, sb).to_double() / sa.length().to_double()
}

///|
/// Whether two JSON documents have the same shape.
///
/// The shapes are the sets of *leaf paths*: `{"a":{"b":1},"c":[1,2]}` has
/// `$.a.b`, `$.c[0]` and `$.c[1]`. Two records with the same keys are alike
/// even when every value differs, and no amount of word-matching will ever say
/// so.
///
/// A text that is not JSON has no shape, so it scores 0.0 against everything
/// — including against another text that is not JSON, because "neither of
/// these is a document" is not a similarity.
pub fn structure_similarity(a : String, b : String) -> Double {
  let sa = structure_paths(a)
  let sb = structure_paths(b)
  if sa.length() == 0 || sb.length() == 0 {
    return 0.0
  }
  let shared = count_shared(sa, sb)
  let union = sa.length() + sb.length() - shared
  if union == 0 {
    0.0
  } else {
    shared.to_double() / union.to_double()
  }
}

///|
/// The leaf paths of a JSON document, in order.
///
/// A leaf is a value that is not an object or an array, and its path is the
/// way to it: `$.a.b`, `$.c[0]`. A text that is not JSON has no paths.
pub fn structure_paths(text : String) -> Array[String] {
  let parsed = @json.parse(text) catch { _ => return [] }
  let out : Array[String] = []
  collect_paths(parsed, "$", out)
  out
}

///|
/// The paths of everything under a value, appended to `out`.
fn collect_paths(value : Json, path : String, out : Array[String]) -> Unit {
  match value {
    Json::Object(obj) =>
      for (k, child) in obj.iter() {
        collect_paths(child, path + "." + k, out)
      }
    Json::Array(items) => {
      let mut i = 0
      while i < items.length() {
        collect_paths(items[i], path + "[" + i.to_string() + "]", out)
        i = i + 1
      }
    }
    _ => out.push(path)
  }
}

///|
/// How many of the items in `a` also appear in `b`.
fn count_shared(a : Array[String], b : Array[String]) -> Int32 {
  let mut shared = 0
  for item in a {
    if b.contains(item) {
      shared = shared + 1
    }
  }
  shared
}

///|
/// The distinct words of a text and how many times each appears.
fn token_counts(text : String) -> Array[(String, Int32)] {
  let out : Array[(String, Int32)] = []
  for token in tokenize(text) {
    match index_of_token(out, token) {
      Some(i) => {
        let (name, count) = out[i]
        out[i] = (name, count + 1)
      }
      None => out.push((token, 1))
    }
  }
  out
}

///|
/// The position of a token in a count list, or `None`.
fn index_of_token(counts : Array[(String, Int32)], token : String) -> Int32? {
  let mut i = 0
  while i < counts.length() {
    if counts[i].0 == token {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// How many times a token appears in a count list.
fn count_of(counts : Array[(String, Int32)], token : String) -> Int32 {
  match index_of_token(counts, token) {
    None => 0
    Some(i) => counts[i].1
  }
}
