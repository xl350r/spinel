# Regression test: an initialize parameter that is never written to an
# ivar must still pick up its type from `Foo.new(...)` call sites.
#
# Before the fix, body inference (which returns "int" when no `@x = x`
# write is found) unconditionally overwrote the call-site-inferred type,
# silently miscompiling code where the parameter was a string, array, or
# any other concrete type.

class Greeter
  def initialize(name)
    puts name
  end
end

Greeter.new("hello")
