# Hash#transform_values for int_str_hash. str_int_hash's
# transform_values already shipped; this extends to int-keyed-str
# hashes. The block runs once per value, its return becomes the new
# value, keys and order preserved.

# Identity transform — values unchanged
h1 = {1 => "alpha", 2 => "beta"}
puts h1.transform_values { |v| v }[1]
puts h1.transform_values { |v| v }[2]

# Upcase values
h2 = {1 => "hello", 2 => "world"}
upper = h2.transform_values { |v| v.upcase }
puts upper[1]
puts upper[2]

# String concat
h3 = {1 => "a", 2 => "b", 3 => "c"}
suff = h3.transform_values { |v| v + "!" }
puts suff[1]
puts suff[2]
puts suff[3]

# Length preserved across transform
big = {10 => "one", 20 => "two", 30 => "three"}
puts big.transform_values { |v| v + "?" }.length

# Empty block maps every value to nil (CRuby parity).
# For int_str_hash the value type is `const char *`; nil → NULL.
empty = {1 => "alpha", 2 => "beta"}.transform_values { }
puts empty[1].nil?
puts empty[2].nil?
puts empty.length
