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
end

obj = Builder.new.make(0)
puts obj.read(41)
