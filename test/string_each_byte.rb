# String#each_byte iterates the bytes of a string. Mirrors each_char
# but yields the (unsigned) byte value at each position rather than
# a single-char substring. ASCII-only test pins parity with CRuby's
# byte-level iteration. Multi-byte UTF-8 prints the underlying byte
# values, not codepoints (matches CRuby).

# ASCII string
"ab".each_byte { |b| puts b }

# Empty string yields nothing
"".each_byte { |b| puts b }

# Mixed alphabetic and digit
"A1z".each_byte { |b| puts b }

# Newline byte
"a\n".each_byte { |b| puts b }

# Multi-byte UTF-8 (Latin Small Letter E with Acute): byte iteration, not codepoint
"é".each_byte { |b| puts b }

# Counted iteration via accumulator
total = 0
"hello".each_byte { |b| total = total + b }
puts total

# String#each_byte returns the receiver (CRuby parity). Pre-fix Spinel's
# each_byte was statement-only and the assignment dropped the value.
total2 = 0
ret = "hello".each_byte { |b| total2 = total2 + b }
puts total2
puts ret
