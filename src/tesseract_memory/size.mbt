///|
/// The UTF-8 size of a text, in bytes.
///
/// `String::length` counts **code units**, not bytes: `苹果` is 2 and `🍎` is
/// 2, while in UTF-8 they are 6 and 4. A budget measured in bytes has to be
/// in bytes, or the number moves under the caller's feet depending on the
/// language of the text — and a memory whose budget shrinks when the content
/// is in Chinese is a memory nobody can reason about.
///
/// The walk follows the UTF-16 code units the runtime hands out:
///
/// | code unit | bytes |
/// |---|---|
/// | below `0x80` | 1 |
/// | below `0x800` | 2 |
/// | a surrogate pair | 4 |
/// | anything else | 3 |
pub fn utf8_bytes(text : String) -> Int64 {
  let n = text.length()
  let mut bytes = 0L
  let mut i = 0
  while i < n {
    let u = text.at(i).to_int()
    if u < 128 {
      bytes = bytes + 1L
      i = i + 1
    } else if u < 2048 {
      bytes = bytes + 2L
      i = i + 1
    } else if u >= 55296 && u <= 56319 && i + 1 < n {
      // A high surrogate followed by a low one is one character, and it is
      // four bytes in UTF-8.
      let low = text.at(i + 1).to_int()
      if low >= 56320 && low <= 57343 {
        bytes = bytes + 4L
        i = i + 2
      } else {
        bytes = bytes + 3L
        i = i + 1
      }
    } else {
      bytes = bytes + 3L
      i = i + 1
    }
  }
  bytes
}
