; GPL-3.0-or-later. See ../../../../COPYING.
; inherits: mua

; `export name` and `call f(x)` parse as applications of a name; they are Nua's keywords
((call_expression function: (identifier) @keyword) (#any-of? @keyword "call" "export"))

((identifier) @type.builtin
 (#any-of? @type.builtin "I8" "I16" "I32" "I64" "U8" "U16" "U32" "U64" "F32" "F64" "Bool" "Str" "CString" "Chars" "Text" "Array" "Ref" "Ptr" "Slice" "Store" "Id" "Grow" "Atomic"))
