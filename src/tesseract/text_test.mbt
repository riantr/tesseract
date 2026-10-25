///|
/// The text helpers that pad a column and cut it short.
///
/// Padding is for tables: a column is padded to a width so the next one starts
/// in the same place. The two directions differ in one thing that is easy to
/// get wrong — which end of the text the spaces go on — so they are asserted
/// against each other rather than one at a time.
///
/// Neither ever cuts. A text longer than the width is left whole, because a
/// column that cut its text would lose it, and a lost column is a silent
/// change to what the table says.
test "padding puts the spaces on one end, and never cuts" {
  // The two directions, side by side.
  assert_eq(@tesseract.pad_left("ab", 5), "   ab")
  assert_eq(@tesseract.pad_right("ab", 5), "ab   ")
  // A text that is exactly the width is not padded.
  assert_eq(@tesseract.pad_left("ab", 2), "ab")
  assert_eq(@tesseract.pad_right("ab", 2), "ab")
  // A text longer than the width is left whole rather than cut.
  assert_eq(@tesseract.pad_left("abcdef", 3), "abcdef")
  assert_eq(@tesseract.pad_right("abcdef", 3), "abcdef")
  // And the empty text is padded like any other.
  assert_eq(@tesseract.pad_left("", 3), "   ")
  assert_eq(@tesseract.pad_right("", 3), "   ")
}
