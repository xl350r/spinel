# Test nested ConstantPath reads (A::B::C, M::C::X).

module A
  module B
    C = 7
  end
end

module M
  class C
    X = 11
  end
end

puts A::B::C
puts M::C::X
