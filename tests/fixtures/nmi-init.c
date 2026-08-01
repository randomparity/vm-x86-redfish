#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static int console_fd = STDERR_FILENO;

static void write_all(int fd, const char *message) {
  size_t remaining = strlen(message);

  while (remaining > 0) {
    ssize_t written = write(fd, message, remaining);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      return;
    }
    message += written;
    remaining -= (size_t)written;
  }
}

static void write_console(const char *message) { write_all(console_fd, message); }

static _Noreturn void unsupported(const char *operation) {
  write_console("NMI_UNSUPPORTED: ");
  write_console(operation);
  write_console("\n");
  _exit(EXIT_FAILURE);
}

static void prepare_console(void) {
  if (mkdir("/dev", 0755) < 0 && errno != EEXIST) {
    unsupported("mkdir /dev");
  }
  if (mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1)) < 0 && errno != EEXIST) {
    unsupported("mknod /dev/console");
  }
  console_fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
  if (console_fd < 0) {
    console_fd = STDERR_FILENO;
    unsupported("open /dev/console");
  }
}

static int read_expected(const char *path, const char *expected) {
  char value[16];
  ssize_t length;
  int fd = open(path, O_RDONLY | O_CLOEXEC);

  if (fd < 0) {
    return -1;
  }
  do {
    length = read(fd, value, sizeof(value));
  } while (length < 0 && errno == EINTR);
  if (close(fd) < 0 || length < 0) {
    return -1;
  }
  return (size_t)length == strlen(expected) && memcmp(value, expected, (size_t)length) == 0
             ? 0
             : -1;
}

int main(void) {
  prepare_console();
  if (mkdir("/proc", 0555) < 0 && errno != EEXIST) {
    unsupported("mkdir /proc");
  }
  if (mount("proc", "/proc", "proc", 0, NULL) < 0) {
    unsupported("mount /proc");
  }
  if (read_expected("/proc/sys/kernel/unknown_nmi_panic", "1\n") < 0) {
    unsupported("verify unknown_nmi_panic=1");
  }
  if (read_expected("/proc/sys/kernel/panic", "1\n") < 0) {
    unsupported("verify panic=1");
  }
  write_console("NMI_READY\n");
  for (;;) {
    pause();
  }
}
