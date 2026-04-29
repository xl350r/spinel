# Test hash.keys.each fusion for all hash types

# int_str_hash: integer keys
h1 = {3 => "Fizz", 5 => "Buzz", 7 => "Bazz"}
h1.keys.each do |ki|
  puts ki
end
# => 3 5 7

# str_str_hash: string keys
h2 = {"a" => "apple", "b" => "banana", "c" => "cherry"}
h2.keys.each do |ks|
  puts ks
end
# => a b c

# str_int_hash: string keys, integer values
h3 = {"x" => 10, "y" => 20, "z" => 30}
h3.keys.each do |ks2|
  puts ks2
end
# => x y z

# body reads value via lookup
total = 0
{10 => "ten", 20 => "twenty", 30 => "thirty"}.keys.each do |n|
  total = total + n
end
puts total
# => 60

# common pattern: conditional accumulation
map = {3 => "Fizz", 5 => "Buzz"}
output = ""
map.keys.each do |d|
  if 15 % d == 0
    output = output + map[d]
  end
end
puts output
# => FizzBuzz

# no block param
count = 0
{"a" => 1, "b" => 2}.keys.each do
  count = count + 1
end
puts count
# => 2
