# Regression test: when an `initialize` parameter is widened to "poly"
# by conflicting Foo.new(...) call sites, the param type must stay poly
# end-to-end. The extended merge logic explicitly returns existing_pt
# when it is "poly" so that body inference (which can return a narrower
# concrete type via super-call propagation or via the @ivar's type when
# the ivar was seeded by a literal write elsewhere) does not silently
# narrow the param back.

class Box
  def initialize(v)
    @v = v
  end

  def show
    puts @v
  end
end

Box.new("hello").show
Box.new(42).show
