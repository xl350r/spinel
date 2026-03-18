# Test Hash support

# Hash literal
h = {}
h["one"] = 1
h["two"] = 2
h["three"] = 3
puts h["two"]    # 2
puts h.length    # 3

# Iteration
h.each do |k, v|
  puts k
end

# keys
puts h.keys.length  # 3

# has_key?
if h.has_key?("two")
  puts "found"
end

# delete
h.delete("two")
puts h.length  # 2
