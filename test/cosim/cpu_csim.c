/* CPU shim + OCaml FFI for the differential lockstep (Layers 2 & 3).
 *
 * Including risc.c (vendored verbatim from oberon-risc-emu) reaches its static
 * risc_single_step and the struct RISC fields without modifying the reference.
 * A single persistent machine mirrors the OCaml side; RAM is calloc'd (zeroed),
 * matching the OCaml port's zero-initialised RAM, so out-of-region memory stays
 * in sync across cases.
 *
 * load / step / dump primitives share a buffer:
 *   [0]=PC  [1..16]=R0..R15  [17]=H  [18]=flags(Z|N<<1|C<<2|V<<3)
 *   [19..]=RAM[0 .. (len-19-1)]   (the region size is the buffer length - 19) */
#include <stdint.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/bigarray.h>
#include "risc.c"
#include "risc_fp.c" /* fp_* definitions risc.c's FP ops call */

static struct RISC *g = NULL;

CAMLprim value ml_cpu_load(value ba) {
  CAMLparam1(ba);
  if (!g) g = risc_new();
  int32_t *p = (int32_t *)Caml_ba_data_val(ba);
  intnat n = Caml_ba_array_val(ba)->dim[0] - 19;
  g->PC = (uint32_t)p[0];
  for (int i = 0; i < 16; i++) g->R[i] = (uint32_t)p[1 + i];
  g->H = (uint32_t)p[17];
  uint32_t f = (uint32_t)p[18];
  g->Z = (f & 1) != 0;
  g->N = (f & 2) != 0;
  g->C = (f & 4) != 0;
  g->V = (f & 8) != 0;
  for (intnat i = 0; i < n; i++) g->RAM[i] = (uint32_t)p[19 + i];
  CAMLreturn(Val_unit);
}

CAMLprim value ml_cpu_step(value unit) {
  (void)unit;
  risc_single_step(g); /* static, visible via #include */
  return Val_unit;
}

CAMLprim value ml_cpu_dump(value ba) {
  CAMLparam1(ba);
  int32_t *p = (int32_t *)Caml_ba_data_val(ba);
  intnat n = Caml_ba_array_val(ba)->dim[0] - 19;
  p[0] = (int32_t)g->PC;
  for (int i = 0; i < 16; i++) p[1 + i] = (int32_t)g->R[i];
  p[17] = (int32_t)g->H;
  p[18] = (int32_t)((g->Z ? 1u : 0u) | (g->N ? 2u : 0u) | (g->C ? 4u : 0u) | (g->V ? 8u : 0u));
  for (intnat i = 0; i < n; i++) p[19 + i] = (int32_t)g->RAM[i];
  CAMLreturn(Val_unit);
}
