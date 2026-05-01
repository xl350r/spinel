# Issue #156: transpose for nested int arrays.
# Inspect of nested arrays still prints "#<Object>" (separate issue),
# so each test reads element-wise to keep the comparison meaningful.

m = [[1, 2], [3, 4]]
t = m.transpose
puts t.length
puts t[0][0]
puts t[0][1]
puts t[1][0]
puts t[1][1]

# 2x3 -> 3x2
m2 = [[1, 2, 3], [4, 5, 6]]
t2 = m2.transpose
puts t2.length
puts t2[0][0]
puts t2[0][1]
puts t2[1][0]
puts t2[1][1]
puts t2[2][0]
puts t2[2][1]

# 1x3 -> 3x1
m3 = [[7, 8, 9]]
t3 = m3.transpose
puts t3.length
puts t3[0][0]
puts t3[1][0]
puts t3[2][0]
