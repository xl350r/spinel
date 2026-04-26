# Regression test for issue #17: locals inside `initialize` were not
# declared in the generated `_new` constructor (and `_initialize`
# helper for value-type classes), so cc rejected the body with
# `'lv_x' undeclared`.

class Test
  attr_reader :a
  def initialize
    x = 1
    @a = x
  end
end

class Sum
  attr_reader :total
  def initialize(n)
    s = 0
    i = 0
    while i < n
      s = s + i
      i = i + 1
    end
    @total = s
  end
end

class Compound
  attr_reader :result
  def initialize(x, y)
    a = x * 2
    b = y + 1
    @result = a + b
  end
end

t = Test.new
puts t.a              # 1

s = Sum.new(5)
puts s.total          # 10

c = Compound.new(3, 4)
puts c.result         # 11
