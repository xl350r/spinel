# Test sp_String additional methods

# replace
s = "hello"
s.replace("world")
puts s          # world

# clear
s.clear
puts s.length   # 0

# [] on mutable string
s2 = "abcdef"
s2 << "ghi"
puts s2[0]      # a
puts s2[-1]     # i
puts s2.length  # 9

# gsub on mutable string
s3 = "hello"
s3 << " world"
puts s3.gsub("o", "0")  # hell0 w0rld

# split on mutable string
s4 = "a"
s4 << ",b,c"
parts = s4.split(",")
puts parts.length  # 3

# + on mutable (creates new string, does not mutate)
s5 = "foo"
s5 << "bar"
s6 = s5 + "baz"
puts s5        # foobar (unchanged)
puts s6        # foobarbaz

# to_s
s7 = "test"
s7 << "ing"
puts s7.to_s   # testing

puts "done"
