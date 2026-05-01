# Hash#transform_keys for str_int_hash. The block runs once per key,
# its return value becomes the new key. Mirrors transform_values'
# shape (which already shipped) but on the key axis.

# Identity transform — keys unchanged
h1 = {"alpha" => 1, "beta" => 2}
puts h1.transform_keys { |k| k }["alpha"]
puts h1.transform_keys { |k| k }["beta"]

# Upcase keys
h2 = {"hello" => 10, "world" => 20}
upper = h2.transform_keys { |k| k.upcase }
puts upper["HELLO"]
puts upper["WORLD"]
puts upper.has_key?("hello")
puts upper.has_key?("HELLO")

# Concat suffix
h3 = {"a" => 100, "b" => 200}
suff = h3.transform_keys { |k| k + "_x" }
puts suff["a_x"]
puts suff["b_x"]

# Empty hash transform
empty = {}
empty["k"] = 1
empty.delete("k")
puts empty.transform_keys { |k| k.upcase }.length

# Length preserved
big = {"one" => 1, "two" => 2, "three" => 3}
puts big.transform_keys { |k| k + "!" }.length
