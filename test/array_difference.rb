# Array#difference for typed arrays (int/sym/str/float).
# Mirrors Array#intersection (c31b618) and Array#union — keep only
# elements of self NOT present in other (deduplicated).

# int_array
puts [1, 2, 3, 4].difference([2, 4]).inspect
puts [1, 2, 3].difference([4, 5]).inspect
puts [1, 2, 3].difference([1, 2, 3]).inspect
puts [].difference([1, 2]).inspect
puts [1, 2].difference([]).inspect
puts [1, 1, 2, 3].difference([1]).inspect
puts [].difference([]).inspect

# str_array
puts ["a", "b", "c"].difference(["b"]).inspect
puts ["x", "y"].difference(["a"]).inspect
puts ["a", "b"].difference(["a", "b"]).inspect
puts ["a", "a", "b"].difference(["a"]).inspect

# float_array
puts [1.0, 2.0, 3.0].difference([2.0]).inspect
puts [1.5, 2.5].difference([3.5]).inspect
puts [1.0, 1.0, 2.0].difference([1.0]).inspect

# sym_array
puts [:a, :b, :c].difference([:b]).inspect
puts [:x, :y].difference([:a]).inspect
puts [:a, :a, :b].difference([:a]).inspect
