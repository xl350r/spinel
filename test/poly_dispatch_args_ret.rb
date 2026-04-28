# Regression test for polymorphic return flow:
# a method returning different class instances from branches.

class A
  def read(v)
    v + 1
  end
end

class B
  def read(v)
    v + 2
  end
end

class Builder
  def make(flag)
    if flag == 0
      A.new
    else
      B.new
    end
  end

  def make_with_return(flag)
    if flag == 0
      return A.new
    end
    return B.new
  end
end

b = Builder.new

obj0 = b.make(0)
puts obj0.read(41)

obj1 = b.make(1)
puts obj1.read(41)

ret0 = b.make_with_return(0)
puts ret0.read(41)

ret1 = b.make_with_return(1)
puts ret1.read(41)
