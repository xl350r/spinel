# Test exception classes

class AppError < RuntimeError
end

class NotFoundError < AppError
end

# Raise custom exception
begin
  raise NotFoundError, "item not found"
rescue NotFoundError => e
  puts e  # item not found
rescue AppError => e
  puts "app error"
end

# Raise with class name
begin
  raise AppError, "something went wrong"
rescue NotFoundError => e
  puts "not found"
rescue AppError => e
  puts e  # something went wrong
end

# Bare rescue catches all
begin
  raise "generic error"
rescue => e
  puts e  # generic error
end

puts "done"
