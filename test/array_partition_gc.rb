# Regression: Array#partition (block form) returns a tuple holding two
# inner arrays. The tuple's sp_gc_alloc was emitted with scan=NULL, so
# the inner arrays were swept while the tuple was still alive, and a
# subsequent allocation reused the freed memory — `parts[0].length`
# came back as the length of whatever object now sat there.

arr = [1, 2, 3, 4, 5, 6]
parts = arr.partition { |x| x.odd? }

# Force many GCs by allocating lots of GC-managed objects.
i = 0
while i < 200000
  tmp = [1, 2, 3]
  tmp.push(i)
  i += 1
end

puts parts[0].length   # 3
puts parts[1].length   # 3
puts "done"
