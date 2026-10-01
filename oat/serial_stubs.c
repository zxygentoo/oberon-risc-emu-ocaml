/* oat's serial line setup — raw 8N1 at a given baud — and its read-back, for
 * Device.open_device.
 *
 * Why not Unix.tcsetattr: OCaml's Unix stubs carry their own baud -> B<rate>
 * table inside the switch's static unix archive. glibc 2.42 changed speed_t
 * from a code to the rate itself, so an archive compiled before a glibc upgrade
 * and linked after it passes the old code as a literal rate (115200 -> 4098
 * baud), and Unix.tcgetattr maps it straight back — the fault is invisible from
 * OCaml. This file is compiled with the project, against the headers of the
 * libc it links to, so its B<rate> constants cannot go stale.
 *
 * Portable POSIX termios only (no Linux termios2/BOTHER). */
#define _DEFAULT_SOURCE /* glibc: CRTSCTS and the rates above 38400 */
#define CAML_NAME_SPACE
#include <stddef.h>
#include <termios.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

/* The standard rates; the ones POSIX does not name are guarded. B0 (hang up)
 * is deliberately not a rate oat can ask for. */
static const struct {
  int baud;
  speed_t speed;
} rates[] = {
  {50, B50},
  {75, B75},
  {110, B110},
  {134, B134},
  {150, B150},
  {200, B200},
  {300, B300},
  {600, B600},
  {1200, B1200},
  {1800, B1800},
  {2400, B2400},
  {4800, B4800},
  {9600, B9600},
  {19200, B19200},
  {38400, B38400},
#ifdef B57600
  {57600, B57600},
#endif
#ifdef B115200
  {115200, B115200},
#endif
#ifdef B230400
  {230400, B230400},
#endif
#ifdef B460800
  {460800, B460800},
#endif
#ifdef B500000
  {500000, B500000},
#endif
#ifdef B576000
  {576000, B576000},
#endif
#ifdef B921600
  {921600, B921600},
#endif
#ifdef B1000000
  {1000000, B1000000},
#endif
#ifdef B1152000
  {1152000, B1152000},
#endif
#ifdef B1500000
  {1500000, B1500000},
#endif
#ifdef B2000000
  {2000000, B2000000},
#endif
#ifdef B2500000
  {2500000, B2500000},
#endif
#ifdef B3000000
  {3000000, B3000000},
#endif
#ifdef B3500000
  {3500000, B3500000},
#endif
#ifdef B4000000
  {4000000, B4000000},
#endif
};

#define N_RATES (sizeof rates / sizeof rates[0])

/* The line mode oat depends on: cfmakeraw's flag set, plus 8N1 with no flow
 * control in either direction and the modem-control lines ignored. One set of
 * masks serves both the setup and the read-back, so they cannot drift apart. */
#ifndef CRTSCTS
#define CRTSCTS 0
#endif
#define IFLAG_OFF                                                              \
  (IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF)
#define OFLAG_OFF (OPOST)
#define LFLAG_OFF (ECHO | ECHONL | ICANON | ISIG | IEXTEN)
#define CFLAG_OFF (CSIZE | PARENB | CSTOPB | CRTSCTS)
#define CFLAG_ON (CS8 | CLOCAL | CREAD)

static int is_raw_8n1(const struct termios *tio) {
  return (tio->c_iflag & IFLAG_OFF) == 0 && (tio->c_oflag & OFLAG_OFF) == 0 &&
         (tio->c_lflag & LFLAG_OFF) == 0 &&
         (tio->c_cflag & (CFLAG_OFF | CFLAG_ON)) == CFLAG_ON &&
         tio->c_cc[VMIN] == 1 && tio->c_cc[VTIME] == 0;
}

/* A speed_t as an integer baud: 0 for B0, -1 for one this platform's table
 * cannot name. Where speed_t is the rate itself (glibc >= 2.42, the BSDs,
 * macOS) an off-table speed is still reported as its number — that is how a
 * wrongly set line (the 4098 above) gets shown for what it is. */
static int baud_of_speed(speed_t speed) {
  if (speed == B0) return 0;
  for (size_t i = 0; i < N_RATES; i++)
    if (rates[i].speed == speed) return rates[i].baud;
  if (B9600 == 9600 && B19200 == 19200) return (int)speed;
  return -1;
}

/* unit -> int array: the rates oat_serial_configure accepts on this platform,
 * ascending. */
CAMLprim value oat_serial_bauds(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  res = caml_alloc_tuple(N_RATES);
  for (size_t i = 0; i < N_RATES; i++) Store_field(res, i, Val_int(rates[i].baud));
  CAMLreturn(res);
}

/* Unix.file_descr -> int -> unit: put the line in raw 8N1 at [baud].
 * Raises Unix_error when the fd is not a terminal or the driver refuses, and
 * Invalid_argument for a baud outside oat_serial_bauds. A driver may accept
 * the call and still not apply everything — hence oat_serial_read_back. */
CAMLprim value oat_serial_configure(value v_fd, value v_baud) {
  int baud = Int_val(v_baud);
  size_t i = 0;
  struct termios tio;
  while (i < N_RATES && rates[i].baud != baud) i++;
  if (i == N_RATES) caml_invalid_argument("oat_serial_configure: unsupported baud");
  if (tcgetattr(Int_val(v_fd), &tio) == -1) caml_uerror("tcgetattr", Nothing);
  tio.c_iflag &= ~(tcflag_t)IFLAG_OFF;
  tio.c_oflag &= ~(tcflag_t)OFLAG_OFF;
  tio.c_lflag &= ~(tcflag_t)LFLAG_OFF;
  tio.c_cflag &= ~(tcflag_t)CFLAG_OFF;
  tio.c_cflag |= CFLAG_ON;
  tio.c_cc[VMIN] = 1;
  tio.c_cc[VTIME] = 0;
  if (cfsetispeed(&tio, rates[i].speed) == -1) caml_uerror("cfsetispeed", Nothing);
  if (cfsetospeed(&tio, rates[i].speed) == -1) caml_uerror("cfsetospeed", Nothing);
  if (tcsetattr(Int_val(v_fd), TCSANOW, &tio) == -1) caml_uerror("tcsetattr", Nothing);
  return Val_unit;
}

/* Unix.file_descr -> int * int * bool: what the line holds now — input baud,
 * output baud (as baud_of_speed renders them), and whether the mode is the raw
 * 8N1 oat_serial_configure sets. Raises Unix_error when the fd is not a
 * terminal. */
CAMLprim value oat_serial_read_back(value v_fd) {
  CAMLparam1(v_fd);
  CAMLlocal1(res);
  struct termios tio;
  if (tcgetattr(Int_val(v_fd), &tio) == -1) caml_uerror("tcgetattr", Nothing);
  res = caml_alloc_tuple(3);
  Store_field(res, 0, Val_int(baud_of_speed(cfgetispeed(&tio))));
  Store_field(res, 1, Val_int(baud_of_speed(cfgetospeed(&tio))));
  Store_field(res, 2, Val_bool(is_raw_8n1(&tio)));
  CAMLreturn(res);
}
