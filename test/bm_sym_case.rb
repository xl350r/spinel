# Symbol in case/when
def classify(sym)
  case sym
  when :red then "warm"
  when :orange then "warm"
  when :blue then "cool"
  when :green then "cool"
  else "unknown"
  end
end

puts classify(:red)     # warm
puts classify(:orange)  # warm
puts classify(:blue)    # cool
puts classify(:purple)  # unknown
