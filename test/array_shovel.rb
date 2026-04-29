# `arr << x` used in expression context (not a top-level statement)
# fell through to a literal C `<<` (bit shift). The stmt-level path
# already lowered `arr << x` to push for typed arrays; the operator/
# expression form did not. gcc rejected the result with "invalid
# operands to binary <<" on a pointer LHS.
#
# Chaining `(arr << x) << y` is the natural expression-context use
# case: the inner `<<` returns the recv, which the outer `<<`
# mutates again. Both the codegen path and `infer_call_type` need
# to know the result is the recv's array type so the outer operand
# type-checks.

ints = [1]
(ints << 2) << 3
puts ints.length    # 3
puts ints[0]        # 1
puts ints[1]        # 2
puts ints[2]        # 3

floats = [1.5]
(floats << 2.5) << 3.5
puts floats.length  # 3
puts floats[2]      # 3.5

strs = ["a"]
(strs << "b") << "c"
puts strs.length    # 3
puts strs[2]        # c

syms = [:x]
(syms << :y) << :z
puts syms.length    # 3
puts syms[2]        # z
