/* OCaml FFI stubs for the C reference's software FP / idiv — Layer 1 of the
 * differential lockstep. These call the vendored risc-fp.c (compiled as
 * risc_fp.c) so the OCaml port can be checked bit-for-bit against the C live.
 *
 * Values cross as OCaml ints holding a u32 (native int is 63-bit on a 64-bit
 * host, so the round-trip is lossless). */
#include <stdint.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include "risc_fp.c" /* pulls in fp_add/fp_mul/fp_div/idiv definitions */

CAMLprim value ml_c_fp_add(value x, value y, value u, value v) {
  return Val_long((long)fp_add((uint32_t)Long_val(x), (uint32_t)Long_val(y),
                               Bool_val(u), Bool_val(v)));
}

CAMLprim value ml_c_fp_mul(value x, value y) {
  return Val_long((long)fp_mul((uint32_t)Long_val(x), (uint32_t)Long_val(y)));
}

CAMLprim value ml_c_fp_div(value x, value y) {
  return Val_long((long)fp_div((uint32_t)Long_val(x), (uint32_t)Long_val(y)));
}

CAMLprim value ml_c_idiv(value x, value y, value s) {
  CAMLparam3(x, y, s);
  CAMLlocal1(res);
  struct idiv d = idiv((uint32_t)Long_val(x), (uint32_t)Long_val(y), Bool_val(s));
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_long((long)d.quot));
  Store_field(res, 1, Val_long((long)d.rem));
  CAMLreturn(res);
}
