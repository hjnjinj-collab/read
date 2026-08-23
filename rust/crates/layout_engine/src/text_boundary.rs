use unicode_segmentation::UnicodeSegmentation;

/// Text boundary handler for safe UTF-8 character operations.
///
/// Provides efficient character-to-byte mapping and safe slicing
/// for multi-byte UTF-8 characters, Emoji, and Grapheme Clusters.
pub struct TextBoundaryHandler {
    /// Character index -> byte offset mapping
    char_to_byte_map: Vec<usize>,
    /// Byte offset -> character index mapping
    byte_to_char_map: Vec<usize>,
    /// Grapheme cluster boundaries (byte offsets)
    grapheme_boundaries: Vec<usize>,
    /// Total byte length
    byte_len: usize,
    /// Total character count
    char_count: usize,
}

impl TextBoundaryHandler {
    /// Create a new boundary handler from a string.
    pub fn from_str(text: &str) -> Self {
        let byte_len = text.len();
        let char_count = text.chars().count();

        // Build character-to-byte mapping
        let mut char_to_byte_map = Vec::with_capacity(char_count + 1);
        for (byte_idx, _) in text.char_indices() {
            char_to_byte_map.push(byte_idx);
        }
        char_to_byte_map.push(byte_len); // End sentinel

        // Build byte-to-character mapping
        let mut byte_to_char_map = vec![0; byte_len + 1];
        for (char_idx, (byte_idx, _)) in text.char_indices().enumerate() {
            byte_to_char_map[byte_idx] = char_idx;
        }
        // Fill gaps for multi-byte characters
        for i in 1..byte_to_char_map.len() {
            if byte_to_char_map[i] == 0 && i > 0 {
                byte_to_char_map[i] = byte_to_char_map[i - 1];
            }
        }

        // Build grapheme cluster boundaries
        let grapheme_boundaries: Vec<usize> = text
            .grapheme_indices(true)
            .map(|(i, _)| i)
            .collect();

        Self {
            char_to_byte_map,
            byte_to_char_map,
            grapheme_boundaries,
            byte_len,
            char_count,
        }
    }

    /// Get the byte offset for a character index.
    ///
    /// Returns the byte offset of the character at the given index,
    /// or the byte length if the index is out of bounds.
    pub fn char_to_byte(&self, char_index: usize) -> usize {
        if char_index >= self.char_count {
            self.byte_len
        } else {
            self.char_to_byte_map[char_index]
        }
    }

    /// Get the character index for a byte offset.
    ///
    /// Returns the character index that contains or precedes the given byte offset.
    pub fn byte_to_char(&self, byte_offset: usize) -> usize {
        if byte_offset >= self.byte_len {
            self.char_count
        } else {
            self.byte_to_char_map[byte_offset]
        }
    }

    /// Get a safe string slice by character indices.
    ///
    /// Returns the substring from `start_char` to `end_char` (exclusive).
    /// Handles multi-byte characters safely.
    pub fn get_char_range<'a>(&self, text: &'a str, start_char: usize, end_char: usize) -> &'a str {
        let start_byte = self.char_to_byte(start_char);
        let end_byte = self.char_to_byte(end_char);

        // Ensure valid UTF-8 boundaries
        let start_byte = find_char_boundary_forward(text.as_bytes(), start_byte);
        let end_byte = find_char_boundary_backward(text.as_bytes(), end_byte);

        if start_byte <= end_byte && end_byte <= text.len() {
            &text[start_byte..end_byte]
        } else {
            ""
        }
    }

    /// Find the nearest character boundary at or after the given byte offset.
    ///
    /// If the offset is already at a boundary, returns the offset.
    /// Otherwise, returns the start of the next character.
    pub fn find_boundary_forward(&self, byte_offset: usize) -> usize {
        if byte_offset >= self.byte_len {
            return self.byte_len;
        }
        let char_idx = self.byte_to_char(byte_offset);
        let boundary = self.char_to_byte(char_idx);

        // If we're not at the boundary, move to the next character
        if boundary < byte_offset {
            self.char_to_byte(char_idx + 1)
        } else {
            boundary
        }
    }

    /// Find the nearest character boundary at or before the given byte offset.
    ///
    /// If the offset is already at a boundary, returns the offset.
    /// Otherwise, returns the start of the current character.
    pub fn find_boundary_backward(&self, byte_offset: usize) -> usize {
        if byte_offset == 0 {
            return 0;
        }
        if byte_offset >= self.byte_len {
            return self.byte_len;
        }
        let char_idx = self.byte_to_char(byte_offset);
        self.char_to_byte(char_idx)
    }

    /// Get the next grapheme cluster boundary after the given byte offset.
    pub fn next_grapheme_boundary(&self, byte_offset: usize) -> usize {
        match self.grapheme_boundaries.binary_search(&byte_offset) {
            Ok(idx) => {
                // Found exact match, return next boundary
                if idx + 1 < self.grapheme_boundaries.len() {
                    self.grapheme_boundaries[idx + 1]
                } else {
                    self.byte_len
                }
            }
            Err(idx) => {
                // Not found, idx is where it would be inserted
                if idx < self.grapheme_boundaries.len() {
                    self.grapheme_boundaries[idx]
                } else {
                    self.byte_len
                }
            }
        }
    }

    /// Get the previous grapheme cluster boundary before the given byte offset.
    pub fn prev_grapheme_boundary(&self, byte_offset: usize) -> usize {
        match self.grapheme_boundaries.binary_search(&byte_offset) {
            Ok(idx) => {
                // Found exact match, return previous boundary
                if idx > 0 {
                    self.grapheme_boundaries[idx - 1]
                } else {
                    0
                }
            }
            Err(idx) => {
                // Not found, idx is where it would be inserted
                if idx > 0 {
                    self.grapheme_boundaries[idx - 1]
                } else {
                    0
                }
            }
        }
    }

    /// Get the total number of characters.
    pub fn char_count(&self) -> usize {
        self.char_count
    }

    /// Get the total byte length.
    pub fn byte_len(&self) -> usize {
        self.byte_len
    }

    /// Get the number of grapheme clusters.
    pub fn grapheme_count(&self) -> usize {
        self.grapheme_boundaries.len()
    }

    /// Check if a byte offset is at a character boundary.
    pub fn is_char_boundary(&self, byte_offset: usize) -> bool {
        if byte_offset == 0 || byte_offset == self.byte_len {
            return true;
        }
        if byte_offset < self.byte_len {
            self.char_to_byte_map[self.byte_to_char_map[byte_offset]] == byte_offset
        } else {
            false
        }
    }

    /// Check if a byte offset is at a grapheme cluster boundary.
    pub fn is_grapheme_boundary(&self, byte_offset: usize) -> bool {
        self.grapheme_boundaries.contains(&byte_offset)
    }
}

/// Find the nearest UTF-8 character boundary at or after the given byte position.
fn find_char_boundary_forward(data: &[u8], pos: usize) -> usize {
    if pos >= data.len() {
        return data.len();
    }
    let mut i = pos;
    while i < data.len() && (data[i] & 0xC0) == 0x80 {
        i += 1;
    }
    i
}

/// Find the nearest UTF-8 character boundary at or before the given byte position.
fn find_char_boundary_backward(data: &[u8], pos: usize) -> usize {
    if pos >= data.len() {
        return data.len();
    }
    let mut i = pos;
    while i > 0 && (data[i] & 0xC0) == 0x80 {
        i -= 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_ascii() {
        let text = "Hello World";
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.char_count(), 11);
        assert_eq!(handler.byte_len(), 11);

        // ASCII: char index == byte offset
        assert_eq!(handler.char_to_byte(0), 0);
        assert_eq!(handler.char_to_byte(5), 5);
        assert_eq!(handler.char_to_byte(10), 10);

        assert_eq!(handler.byte_to_char(0), 0);
        assert_eq!(handler.byte_to_char(5), 5);
        assert_eq!(handler.byte_to_char(10), 10);
    }

    #[test]
    fn test_chinese_characters() {
        let text = "你好世界"; // Each char is 3 bytes
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.char_count(), 4);
        assert_eq!(handler.byte_len(), 12);

        // Character to byte mapping
        assert_eq!(handler.char_to_byte(0), 0);  // '你'
        assert_eq!(handler.char_to_byte(1), 3);  // '好'
        assert_eq!(handler.char_to_byte(2), 6);  // '世'
        assert_eq!(handler.char_to_byte(3), 9);  // '界'
        assert_eq!(handler.char_to_byte(4), 12); // End

        // Byte to character mapping
        assert_eq!(handler.byte_to_char(0), 0);
        assert_eq!(handler.byte_to_char(1), 0); // Still in '你'
        assert_eq!(handler.byte_to_char(2), 0); // Still in '你'
        assert_eq!(handler.byte_to_char(3), 1); // Start of '好'
        assert_eq!(handler.byte_to_char(9), 3); // Start of '界'
    }

    #[test]
    fn test_mixed_content() {
        let text = "Hello你好World"; // Mixed ASCII and Chinese
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.char_count(), 12); // 5 + 2 + 5

        // 'H'=0, 'e'=1, 'l'=2, 'l'=3, 'o'=4
        assert_eq!(handler.char_to_byte(4), 4);

        // '你'=5 (byte 5), '好'=6 (byte 8)
        assert_eq!(handler.char_to_byte(5), 5);
        assert_eq!(handler.char_to_byte(6), 8);

        // 'W'=7 (byte 11)
        assert_eq!(handler.char_to_byte(7), 11);
    }

    #[test]
    fn test_get_char_range() {
        let text = "你好世界测试";
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.get_char_range(text, 0, 2), "你好");
        assert_eq!(handler.get_char_range(text, 2, 4), "世界");
        assert_eq!(handler.get_char_range(text, 0, 6), "你好世界测试");
        assert_eq!(handler.get_char_range(text, 1, 3), "好世");
    }

    #[test]
    fn test_safe_slicing_with_emoji() {
        // Emoji can be 4+ bytes
        let text = "A😀B";
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.char_count(), 3);
        // 'A'=1 byte, '😀'=4 bytes, 'B'=1 byte
        assert_eq!(handler.byte_len(), 6);

        assert_eq!(handler.get_char_range(text, 0, 1), "A");
        assert_eq!(handler.get_char_range(text, 1, 2), "😀");
        assert_eq!(handler.get_char_range(text, 2, 3), "B");
    }

    #[test]
    fn test_boundary_forward_backward() {
        let text = "你好世界";
        let handler = TextBoundaryHandler::from_str(text);

        // Forward boundary
        assert_eq!(handler.find_boundary_forward(0), 0);
        assert_eq!(handler.find_boundary_forward(1), 3); // Skip to '好'
        assert_eq!(handler.find_boundary_forward(5), 6); // Skip to '世'

        // Backward boundary
        assert_eq!(handler.find_boundary_backward(0), 0);
        assert_eq!(handler.find_boundary_backward(3), 3);
        assert_eq!(handler.find_boundary_backward(2), 0); // Back to '你'
        assert_eq!(handler.find_boundary_backward(5), 3); // Back to '好'
    }

    #[test]
    fn test_is_char_boundary() {
        let text = "你好世界";
        let handler = TextBoundaryHandler::from_str(text);

        assert!(handler.is_char_boundary(0));
        assert!(handler.is_char_boundary(3));
        assert!(handler.is_char_boundary(6));
        assert!(handler.is_char_boundary(9));
        assert!(handler.is_char_boundary(12)); // End

        assert!(!handler.is_char_boundary(1));
        assert!(!handler.is_char_boundary(2));
        assert!(!handler.is_char_boundary(4));
        assert!(!handler.is_char_boundary(5));
    }

    #[test]
    fn test_empty_string() {
        let text = "";
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.char_count(), 0);
        assert_eq!(handler.byte_len(), 0);
        assert_eq!(handler.char_to_byte(0), 0);
        assert_eq!(handler.byte_to_char(0), 0);
    }

    #[test]
    fn test_out_of_bounds() {
        let text = "你好";
        let handler = TextBoundaryHandler::from_str(text);

        // Out of bounds should return safe values
        assert_eq!(handler.char_to_byte(100), 6); // Returns byte_len
        assert_eq!(handler.byte_to_char(100), 2); // Returns char_count
        assert_eq!(handler.get_char_range(text, 0, 100), "你好");
    }

    #[test]
    fn test_grapheme_boundaries() {
        // Simple text without complex graphemes
        let text = "Hello";
        let handler = TextBoundaryHandler::from_str(text);

        assert_eq!(handler.grapheme_count(), 5);
        assert!(handler.is_grapheme_boundary(0));
        assert!(handler.is_grapheme_boundary(1));
        assert!(handler.is_grapheme_boundary(4));
        // Note: grapheme_boundaries contains START positions, not end
        // So 5 (end of string) is NOT in the list
        assert!(!handler.is_grapheme_boundary(5));
    }

    #[test]
    fn test_full_roundtrip() {
        let text = "这是一段包含中文、English和Emoji😀的混合文本。";
        let handler = TextBoundaryHandler::from_str(text);

        // Verify we can reconstruct the text using char indices
        let mut reconstructed = String::new();
        for i in 0..handler.char_count() {
            let slice = handler.get_char_range(text, i, i + 1);
            reconstructed.push_str(slice);
        }
        assert_eq!(reconstructed, text);
    }
}
