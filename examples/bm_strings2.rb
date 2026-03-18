# Test additional String methods

str = "  Hello, World!  "
puts str.strip           # "Hello, World!"
puts str.chomp           # "  Hello, World!  " (no trailing newline)

s = "hello world"
puts s.capitalize        # "Hello world"
puts s.reverse           # "dlrow olleh"
puts s.count("lo")       # 5
puts s.start_with?("hel")  # true
puts s.end_with?("rld")    # true
puts s.gsub("l", "L")   # heLLo worLd
puts s.sub("o", "0")    # hell0 world
puts s.split(" ").length # 2

# String repeat
puts "ha" * 3            # hahaha

# String comparison
puts "abc" == "abc"      # true
puts "abc" == "def"      # false
puts "abc" < "def"       # true
