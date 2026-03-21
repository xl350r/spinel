# Spinel lib: strscan
#
# StringScanner — sequential string scanning with regexp.
# Type definitions for Spinel. C implementation in lib/strscan.c.
#
# Link with: cc app.c lib/strscan.c -lonig -lm -o app

class StringScanner
  def initialize(str)
    @source = str
    @pos = 0
    @matched = ""
    @last_pos = 0
  end

  def scan(pattern)
    @matched
  end

  def check(pattern)
    @matched
  end

  def scan_until(pattern)
    @matched
  end

  def matched
    @matched
  end

  def pos
    @pos
  end

  def eos?
    @pos >= @source.length
  end

  def getch
    @matched
  end

  def peek(n)
    @matched
  end

  def unscan
    self
  end

  def rest
    @source
  end
end
