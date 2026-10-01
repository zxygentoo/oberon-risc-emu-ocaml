/* Test-only: open a pseudo-terminal pair for test_oat_device, so
 * Device.open_device can be run against a real tty without hardware. */
#define _GNU_SOURCE /* glibc: posix_openpt, grantpt, unlockpt, ptsname */
#define CAML_NAME_SPACE
#include <fcntl.h>
#include <stdlib.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

/* unit -> Unix.file_descr * string: the master fd and the slave's path. */
CAMLprim value oat_test_openpt(value unit) {
  CAMLparam1(unit);
  CAMLlocal2(res, path);
  const char *name;
  int fd = posix_openpt(O_RDWR | O_NOCTTY);
  if (fd == -1) caml_uerror("posix_openpt", Nothing);
  if (grantpt(fd) == -1) caml_uerror("grantpt", Nothing);
  if (unlockpt(fd) == -1) caml_uerror("unlockpt", Nothing);
  if ((name = ptsname(fd)) == NULL) caml_uerror("ptsname", Nothing);
  path = caml_copy_string(name);
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_int(fd));
  Store_field(res, 1, path);
  CAMLreturn(res);
}
