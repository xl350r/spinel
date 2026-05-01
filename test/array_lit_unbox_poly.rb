# `compile_array_literal`'s int-array fallback pushed elements
# verbatim, including poly-typed ones. When a local was widened to
# poly via cross-branch assignments and then wrapped in an `[x]`
# literal, the generated C had `sp_IntArray_push(arr, <sp_RbVal
# struct>)`, which gcc rejected with "incompatible type for
# argument 2 of sp_IntArray_push". The fix unboxes the int payload
# via `.v.i`. Caller code is responsible for keeping the poly slot
# integer-tagged at the moment the literal is built.

addr = 7
flag = 0
if flag > 0
  # Dead path at runtime — only here to widen `addr` to poly so
  # the array literal lands on the unboxing path.
  addr = "x"
end

# `addr` is poly at compile time (sp_RbVal) but always int=7 at
# runtime. The `[addr]` literal infers as int_array (a single poly
# element falls through to the IntArray branch).
arr = [addr]
puts arr.length          # 1
puts arr[0]              # 7
