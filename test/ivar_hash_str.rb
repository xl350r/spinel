# Test: ivar hash storing string values (issue #64)
# An ivar initialized with {} should be refined to str_str_hash
# when string values are stored via bracket-assign.

class Config
  def initialize
    @data = {}
  end
  def set(key, val)
    @data[key] = val
  end
  def get(key)
    @data[key]
  end
  def size
    @data.length
  end
end

c = Config.new
c.set("name", "alice")
c.set("role", "admin")
puts c.get("name")   # alice
puts c.get("role")   # admin
puts c.size          # 2

# Second object to confirm no state leakage
c2 = Config.new
c2.set("x", "foo")
puts c2.get("x")     # foo
puts c2.size         # 1
