# Test: block argument passed through object method call (issue #65)
# compile_object_method_expr must append the proc literal when the
# target method declares a &blk parameter.

class Counter
  def initialize(limit)
    @limit = limit
  end
  def times_do(&blk)
    i = 0
    while i < @limit
      blk.call(i)
      i = i + 1
    end
  end
end

c = Counter.new(5)
total = 0
c.times_do do |n|
  total = total + n
end
puts total  # 0+1+2+3+4 = 10

# Confirm block can put results
c2 = Counter.new(3)
c2.times_do do |n|
  puts n
end
# 0
# 1
# 2
