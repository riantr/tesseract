///|
/// The UTF-8 size of a text, in bytes.
///
/// `String::length` counts **code units**, not bytes: `苹果` is 2 and `🍎` is
/// 2, while in UTF-8 they are 6 and 4. A budget measured in bytes has to be
/// in bytes, or the number moves under the caller's feet depending on the
/// language of the text — and a memory whose budget shrinks when the content
/// is in Chinese is a memory nobody can reason about.
///
/// The walk goes a **character** at a time rather than a code unit at a time,
/// and a character's own code point says how many bytes it takes:
///
/// | code point | bytes |
/// |---|---|
/// | below `0x80` | 1 |
/// | below `0x800` | 2 |
/// | below `0x10000` | 3 |
/// | anything else | 4 |
pub fn utf8_bytes(text : String) -> Int64 {
  let n = text.length()
  let mut bytes = 0L
  let mut i = 0
  while i < n {
    let (ch, next) = @tesseract.char_at(text, i)
    let cp = ch.to_int()
    if cp < 128 {
      bytes = bytes + 1L
    } else if cp < 2048 {
      bytes = bytes + 2L
    } else if cp < 65536 {
      bytes = bytes + 3L
    } else {
      bytes = bytes + 4L
    }
    i = next
  }
  bytes
}
