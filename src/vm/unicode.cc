// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "src/vm/unicode.h"

#include "src/vm/object.h"

namespace dartino {

const int8_t Utf8::kTrailBytes[256] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 0, 0};

const uint32 Utf8::kMagicBits[7] = {0,  // Padding.
                                    0x00000000, 0x00003080, 0x000E2080,
                                    0x03C82080, 0xFA082080, 0x82082080};

// Minimum values of code points used to check shortest form.
const uint32 Utf8::kOverlongMinimum[7] = {0,  // Padding.
                                          0x0,     0x80,       0x800,
                                          0x10000, 0xFFFFFFFF, 0xFFFFFFFF};

CodePointIterator::CodePointIterator(TwoByteString* str)
    : str_(str), ch_(0), index_(-1), end_(str->length()) {}

bool CodePointIterator::Next() {
  ASSERT(index_ >= -1);
  word length = Utf16::Length(ch_);
  if (index_ < (end_ - length)) {
    index_ += length;
    ch_ = str_->get_code_unit(index_);
    if (Utf16::IsLeadSurrogate(ch_) && (index_ < (end_ - 1))) {
      int32 ch2 = str_->get_code_unit(index_ + 1);
      if (Utf16::IsTrailSurrogate(ch2)) {
        ch_ = Utf16::Decode(ch_, ch2);
      }
    }
    return true;
  }
  index_ = end_;
  return false;
}

intptr_t Utf8::CodeUnitCount(const uint8_t* utf8_array,
                             intptr_t array_len,
                             Type* type) {
  intptr_t len = 0;
  Type char_type = kLatin1;
  for (intptr_t i = 0; i < array_len; i++) {
    uint8_t code_unit = utf8_array[i];
    if (!IsTrailByte(code_unit)) {
      ++len;
      if (!IsLatin1SequenceStart(code_unit)) {  // > U+00FF
        if (IsSupplementarySequenceStart(code_unit)) {  // >= U+10000
          char_type = kSupplementary;
          ++len;
        } else if (char_type == kLatin1) {
          char_type = kBMP;
        }
      }
    }
  }
  *type = char_type;
  return len;
}

word Utf8::Length(int32 ch) {
  if (ch <= kMaxOneByteChar) {
    return 1;
  } else if (ch <= kMaxTwoByteChar) {
    return 2;
  } else if (ch <= kMaxThreeByteChar) {
    return 3;
  }
  ASSERT(ch <= kMaxFourByteChar);
  return 4;
}

word Utf8::Length(TwoByteString* str) {
  word length = 0;
  CodePointIterator it(str);
  while (it.Next()) {
    int32 ch = it.Current();
    length += Utf8::Length(ch);
  }
  return length;
}

word Utf8::Encode(int32 ch, char* dst) {
  static const int kMask = ~(1 << 6);
  if (ch <= kMaxOneByteChar) {
    dst[0] = ch;
    return 1;
  }
  if (ch <= kMaxTwoByteChar) {
    dst[0] = 0xC0 | (ch >> 6);
    dst[1] = 0x80 | (ch & kMask);
    return 2;
  }
  if (ch <= kMaxThreeByteChar) {
    dst[0] = 0xE0 | (ch >> 12);
    dst[1] = 0x80 | ((ch >> 6) & kMask);
    dst[2] = 0x80 | (ch & kMask);
    return 3;
  }
  ASSERT(ch <= kMaxFourByteChar);
  dst[0] = 0xF0 | (ch >> 18);
  dst[1] = 0x80 | ((ch >> 12) & kMask);
  dst[2] = 0x80 | ((ch >> 6) & kMask);
  dst[3] = 0x80 | (ch & kMask);
  return 4;
}

word Utf8::Encode(TwoByteString* src, char* dst, word len) {
  word pos = 0;
  CodePointIterator it(src);
  while (it.Next()) {
    int32 ch = it.Current();
    word num_bytes = Utf8::Length(ch);
    if (pos + num_bytes > len) {
      break;
    }
    Utf8::Encode(ch, &dst[pos]);
    pos += num_bytes;
  }
  return pos;
}

void Utf16::Encode(int32 codepoint, uint16_t* dst) {
  ASSERT(codepoint > Utf16::kMaxCodeUnit);
  ASSERT(dst != NULL);
  dst[0] = (Utf16::kLeadSurrogateOffset + (codepoint >> 10));
  dst[1] = (0xDC00 + (codepoint & 0x3FF));
}

intptr_t Utf8::Decode(const uint8_t* utf8_array,
                      intptr_t array_len,
                      int32_t* dst) {
  uint32_t ch = utf8_array[0] & 0xFF;
  intptr_t i = 1;
  if (ch >= 0x80) {
    intptr_t num_trail_bytes = kTrailBytes[ch];
    bool is_malformed = false;
    for (; i < num_trail_bytes; ++i) {
      if (i < array_len) {
        uint8_t code_unit = utf8_array[i];
        is_malformed |= !IsTrailByte(code_unit);
        ch = (ch << 6) + code_unit;
      } else {
        *dst = -1;
        return 0;
      }
    }
    ch -= kMagicBits[num_trail_bytes];
    if (!((is_malformed == false) &&
          (i == num_trail_bytes) &&
          !Utf::IsOutOfRange(ch) &&
          !IsNonShortestForm(ch, i))) {
      *dst = -1;
      return 0;
    }
  }
  *dst = ch;
  return i;
}

bool Utf8::DecodeToUTF16(const uint8_t* utf8_array,
                         intptr_t array_len,
                         uint16_t* dst,
                         intptr_t len) {
  intptr_t i = 0;
  intptr_t j = 0;
  intptr_t num_bytes;
  for (; (i < array_len) && (j < len); i += num_bytes, ++j) {
    int32_t ch;
    bool is_supplementary = IsSupplementarySequenceStart(utf8_array[i]);
    num_bytes = Utf8::Decode(&utf8_array[i], (array_len - i), &ch);
    if (ch == -1) {
      return false;  // Invalid input.
    }
    if (is_supplementary) {
      Utf16::Encode(ch, &dst[j]);
      j = j + 1;
    } else {
      dst[j] = ch;
    }
  }
  if ((i < array_len) && (j == len)) {
    return false;  // Output overflow.
  }
  return true;  // Success.
}

}  // namespace dartino
