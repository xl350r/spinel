# Nested class definition inside another class.
# Spinel has no namespace table; bare class names must be unique, so
# `class A; class B; ... end; end` registers `B` at top level the same
# way `module M; class B; ... end; end` does.

class A
  class B
    def initialize(x)
      @x = x
    end
    attr_reader :x
  end

  def make_b(x)
    B.new(x)
  end
end

# Direct construction via the path
b = A::B.new(7)
puts b.x

# Construction via the outer class
b2 = A.new.make_b(42)
puts b2.x

# A nested class with its own nested class
class Outer
  class Mid
    class Inner
      def hello
        "hi"
      end
    end
  end
end

puts Outer::Mid::Inner.new.hello
