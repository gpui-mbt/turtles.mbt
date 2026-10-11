/* Darwin-only process-group timeout supervision for the turtles CLI. */

#include <moonbit.h>

#include <stdint.h>

#if defined(__APPLE__)

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static volatile sig_atomic_t turtles_darwin_interrupted = 0;

static void turtles_darwin_note_signal(int signal_number) {
  if (turtles_darwin_interrupted == 0)
    turtles_darwin_interrupted = signal_number;
}

static moonbit_string_t turtles_darwin_utf8_to_string(
  const unsigned char *input,
  size_t length
) {
  size_t units = 0;
  for (size_t i = 0; i < length;) {
    unsigned char first = input[i];
    uint32_t codepoint;
    size_t width;
    if (first < 0x80) {
      codepoint = first;
      width = 1;
    } else if ((first & 0xE0) == 0xC0) {
      if (i + 1 >= length || (input[i + 1] & 0xC0) != 0x80)
        return moonbit_make_string_raw(0);
      codepoint = ((uint32_t)(first & 0x1F) << 6) |
                  (uint32_t)(input[i + 1] & 0x3F);
      width = 2;
      if (codepoint < 0x80)
        return moonbit_make_string_raw(0);
    } else if ((first & 0xF0) == 0xE0) {
      if (i + 2 >= length || (input[i + 1] & 0xC0) != 0x80 ||
          (input[i + 2] & 0xC0) != 0x80)
        return moonbit_make_string_raw(0);
      codepoint = ((uint32_t)(first & 0x0F) << 12) |
                  ((uint32_t)(input[i + 1] & 0x3F) << 6) |
                  (uint32_t)(input[i + 2] & 0x3F);
      width = 3;
      if (codepoint < 0x800 || (codepoint >= 0xD800 && codepoint <= 0xDFFF))
        return moonbit_make_string_raw(0);
    } else if ((first & 0xF8) == 0xF0) {
      if (i + 3 >= length || (input[i + 1] & 0xC0) != 0x80 ||
          (input[i + 2] & 0xC0) != 0x80 || (input[i + 3] & 0xC0) != 0x80)
        return moonbit_make_string_raw(0);
      codepoint = ((uint32_t)(first & 0x07) << 18) |
                  ((uint32_t)(input[i + 1] & 0x3F) << 12) |
                  ((uint32_t)(input[i + 2] & 0x3F) << 6) |
                  (uint32_t)(input[i + 3] & 0x3F);
      width = 4;
      if (codepoint < 0x10000 || codepoint > 0x10FFFF)
        return moonbit_make_string_raw(0);
    } else {
      return moonbit_make_string_raw(0);
    }
    units += codepoint > 0xFFFF ? 2 : 1;
    i += width;
  }

  if (units > INT32_MAX)
    return moonbit_make_string_raw(0);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)units);
  size_t output = 0;
  for (size_t i = 0; i < length;) {
    unsigned char first = input[i];
    uint32_t codepoint;
    size_t width;
    if (first < 0x80) {
      codepoint = first;
      width = 1;
    } else if ((first & 0xE0) == 0xC0) {
      codepoint = ((uint32_t)(first & 0x1F) << 6) |
                  (uint32_t)(input[i + 1] & 0x3F);
      width = 2;
    } else if ((first & 0xF0) == 0xE0) {
      codepoint = ((uint32_t)(first & 0x0F) << 12) |
                  ((uint32_t)(input[i + 1] & 0x3F) << 6) |
                  (uint32_t)(input[i + 2] & 0x3F);
      width = 3;
    } else {
      codepoint = ((uint32_t)(first & 0x07) << 18) |
                  ((uint32_t)(input[i + 1] & 0x3F) << 12) |
                  ((uint32_t)(input[i + 2] & 0x3F) << 6) |
                  (uint32_t)(input[i + 3] & 0x3F);
      width = 4;
    }
    if (codepoint <= 0xFFFF) {
      result[output++] = (uint16_t)codepoint;
    } else {
      codepoint -= 0x10000;
      result[output++] = (uint16_t)(0xD800 + (codepoint >> 10));
      result[output++] = (uint16_t)(0xDC00 + (codepoint & 0x3FF));
    }
    i += width;
  }
  return result;
}

int32_t turtles_is_darwin(void) {
  return 1;
}

moonbit_string_t turtles_darwin_executable_path(void) {
  uint32_t capacity = PATH_MAX;
  char *raw = (char *)malloc(capacity);
  if (raw == NULL)
    return moonbit_make_string_raw(0);
  if (_NSGetExecutablePath(raw, &capacity) != 0) {
    char *larger = (char *)realloc(raw, capacity);
    if (larger == NULL) {
      free(raw);
      return moonbit_make_string_raw(0);
    }
    raw = larger;
    if (_NSGetExecutablePath(raw, &capacity) != 0) {
      free(raw);
      return moonbit_make_string_raw(0);
    }
  }

  char resolved[PATH_MAX];
  if (realpath(raw, resolved) == NULL) {
    free(raw);
    return moonbit_make_string_raw(0);
  }
  moonbit_string_t result = turtles_darwin_utf8_to_string(
    (const unsigned char *)resolved,
    strlen(resolved));
  free(raw);
  return result;
}

static char **turtles_darwin_unpack_argv(moonbit_bytes_t packed, int *argc) {
  int32_t length = Moonbit_array_length(packed);
  if (length <= 0 || packed[length - 1] != 0)
    return NULL;
  int count = 0;
  for (int32_t i = 0; i < length; ++i)
    if (packed[i] == 0)
      ++count;
  if (count == 0)
    return NULL;

  char **argv = (char **)calloc((size_t)count + 1, sizeof(char *));
  char *storage = (char *)malloc((size_t)length);
  if (argv == NULL || storage == NULL) {
    free(argv);
    free(storage);
    return NULL;
  }
  memcpy(storage, packed, (size_t)length);
  int index = 0;
  argv[index++] = storage;
  for (int32_t i = 0; i < length - 1; ++i) {
    if (storage[i] == 0 && index < count)
      argv[index++] = storage + i + 1;
  }
  argv[count] = NULL;
  *argc = count;
  return argv;
}

static void turtles_darwin_free_argv(char **argv) {
  if (argv != NULL) {
    free(argv[0]);
    free(argv);
  }
}

static char *turtles_darwin_find_executable(const char *command) {
  if (strchr(command, '/') != NULL)
    return strdup(command);

  const char *path = getenv("PATH");
  if (path == NULL)
    path = "/usr/bin:/bin";
  const char *component = path;
  for (;;) {
    const char *separator = strchr(component, ':');
    size_t directory_length = separator == NULL
      ? strlen(component)
      : (size_t)(separator - component);
    const char *directory = component;
    if (directory_length == 0) {
      directory = ".";
      directory_length = 1;
    }
    size_t command_length = strlen(command);
    if (directory_length <= SIZE_MAX - command_length - 2) {
      size_t candidate_length = directory_length + command_length + 1;
      char *candidate = (char *)malloc(candidate_length + 1);
      if (candidate == NULL)
        return NULL;
      memcpy(candidate, directory, directory_length);
      candidate[directory_length] = '/';
      memcpy(candidate + directory_length + 1, command, command_length + 1);
      if (access(candidate, X_OK) == 0)
        return candidate;
      free(candidate);
    }
    if (separator == NULL)
      break;
    component = separator + 1;
  }
  errno = ENOENT;
  return NULL;
}

static int turtles_darwin_wait_for_exit(pid_t child, siginfo_t *status) {
  for (;;) {
    memset(status, 0, sizeof(*status));
    if (waitid(P_PID, (id_t)child, status, WEXITED | WNOHANG | WNOWAIT) == 0) {
      if (status->si_pid != 0)
        return 1;
      return 0;
    }
    if (errno == EINTR)
      return 0;
    return -1;
  }
}

static int turtles_darwin_remaining_poll_ms(const struct timespec *deadline) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
    return -1;
  if (now.tv_sec > deadline->tv_sec ||
      (now.tv_sec == deadline->tv_sec && now.tv_nsec >= deadline->tv_nsec))
    return 0;
  int64_t seconds = (int64_t)deadline->tv_sec - (int64_t)now.tv_sec;
  int64_t nanoseconds = (int64_t)deadline->tv_nsec - (int64_t)now.tv_nsec;
  int64_t remaining_ns = seconds * 1000000000LL + nanoseconds;
  if (remaining_ns < 1)
    return 1;
  int64_t remaining_ms = (remaining_ns + 999999LL) / 1000000LL;
  return remaining_ms > 10 ? 10 : (int)remaining_ms;
}

/* Return 1 after exec closes the CLOEXEC pipe, 0 with errno from failed exec,
 * -2 when cancelled, -3 at deadline, and -1 on I/O failure. */
static int turtles_darwin_wait_for_exec(
  int fd,
  pid_t child,
  bool *child_group_ready,
  const struct timespec *deadline,
  int *exec_error
) {
  bool got_bytes = false;
  size_t offset = 0;
  while (offset < sizeof(*exec_error)) {
    /* A signal can arrive after the caller's last check and before this
     * nonblocking read. Observe that already-pending delivery explicitly;
     * relying on EINTR alone misses it when the pipe is ready. */
    if (turtles_darwin_interrupted != 0)
      return -2;
    ssize_t count = read(fd, (char *)exec_error + offset, sizeof(*exec_error) - offset);
    if (count > 0) {
      offset += (size_t)count;
      got_bytes = true;
      continue;
    }
    if (count == 0) {
      if (got_bytes)
        return -1;
      *child_group_ready = true;
      return 1;
    }
    if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
      return -1;

    /* A successful exec is only possible after the child has joined its own
     * group. Confirm that race before deciding whether a direct-PID kill is
     * safe while the CLOEXEC pipe is still open. */
    if (!*child_group_ready && getpgid(child) == child)
      *child_group_ready = true;
    if (turtles_darwin_interrupted != 0)
      return -2;
    int wait_ms = turtles_darwin_remaining_poll_ms(deadline);
    if (wait_ms < 0)
      return -1;
    if (wait_ms == 0)
      return -3;
    struct pollfd descriptor = { .fd = fd, .events = POLLIN | POLLHUP };
    int polled = poll(&descriptor, 1, wait_ms);
    if (polled < 0 && errno != EINTR)
      return -1;
  }
  return 0;
}

static int turtles_darwin_reap(pid_t child, int *status) {
  for (;;) {
    pid_t waited = waitpid(child, status, 0);
    if (waited == child)
      return 0;
    if (waited < 0 && errno == EINTR)
      continue;
    return -1;
  }
}

static int turtles_darwin_status_from_siginfo(const siginfo_t *status) {
  if (status->si_code == CLD_EXITED)
    return status->si_status;
  if (status->si_code == CLD_KILLED || status->si_code == CLD_DUMPED)
    return 128 + status->si_status;
  return 255;
}

static int turtles_darwin_reap_bounded(
  pid_t child,
  int *wait_status,
  bool *reaped
) {
  struct timespec deadline;
  if (clock_gettime(CLOCK_MONOTONIC, &deadline) < 0)
    return -1;
  deadline.tv_sec += 2;
  for (;;) {
    siginfo_t child_info;
    int exited = turtles_darwin_wait_for_exit(child, &child_info);
    if (exited < 0)
      return -1;
    if (exited == 1) {
      if (turtles_darwin_reap(child, wait_status) < 0)
        return -1;
      *reaped = true;
      return 0;
    }
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
      return -1;
    if (now.tv_sec > deadline.tv_sec ||
        (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec)) {
      errno = ETIMEDOUT;
      return -1;
    }
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000L };
    while (nanosleep(&pause, &pause) < 0 && errno == EINTR)
      ;
  }
}

static int turtles_darwin_kill_group_and_reap(
  pid_t child,
  int *wait_status,
  bool *reaped
) {
  /* Do not reap the group leader before this kill: its PID is also the PGID. */
  int kill_error = 0;
  if (kill(-child, SIGKILL) < 0 && errno != ESRCH) {
    kill_error = errno;
    (void)kill(child, SIGKILL);
  }
  if (turtles_darwin_reap_bounded(child, wait_status, reaped) < 0 &&
      kill_error == 0)
    kill_error = errno;
  if (kill_error != 0) {
    errno = kill_error;
    return -1;
  }
  return 0;
}

static int turtles_darwin_install_handler(
  int signal_number,
  struct sigaction *previous
) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = turtles_darwin_note_signal;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  return sigaction(signal_number, &action, previous);
}

static void turtles_darwin_restore_handler(
  int signal_number,
  const struct sigaction *previous
) {
  (void)sigaction(signal_number, previous, NULL);
}

int32_t turtles_darwin_supervise(int32_t timeout_ms, moonbit_bytes_t packed) {
  int error_number = 0;
  int result = -1;
  int argc = 0;
  char **argv = NULL;
  char *executable = NULL;
  int exec_pipe[2] = { -1, -1 };
  pid_t child = -1;
  bool child_group_ready = false;
  bool child_reaped = false;
  bool child_exec_failed = false;
  int child_status = 0;
  struct sigaction old_term;
  struct sigaction old_int;
  struct sigaction old_hup;
  struct sigaction default_action;
  bool term_installed = false;
  bool int_installed = false;
  bool hup_installed = false;
  bool signal_mask_saved = false;
  sigset_t watched_signals;
  sigset_t previous_signal_mask;

  if (timeout_ms <= 0) {
    error_number = EINVAL;
    goto cleanup;
  }
  sigemptyset(&watched_signals);
  sigaddset(&watched_signals, SIGTERM);
  sigaddset(&watched_signals, SIGINT);
  sigaddset(&watched_signals, SIGHUP);
  int mask_error = pthread_sigmask(
    SIG_BLOCK,
    &watched_signals,
    &previous_signal_mask);
  if (mask_error != 0) {
    error_number = mask_error;
    goto cleanup;
  }
  signal_mask_saved = true;
  turtles_darwin_interrupted = 0;
  if (turtles_darwin_install_handler(SIGTERM, &old_term) < 0) {
    error_number = errno;
    goto cleanup;
  }
  term_installed = true;
  if (turtles_darwin_install_handler(SIGINT, &old_int) < 0) {
    error_number = errno;
    goto cleanup;
  }
  int_installed = true;
  if (turtles_darwin_install_handler(SIGHUP, &old_hup) < 0) {
    error_number = errno;
    goto cleanup;
  }
  hup_installed = true;
  memset(&default_action, 0, sizeof(default_action));
  default_action.sa_handler = SIG_DFL;
  sigemptyset(&default_action.sa_mask);

  argv = turtles_darwin_unpack_argv(packed, &argc);
  if (argv == NULL || argc < 1 || argv[0][0] == '\0') {
    error_number = EINVAL;
    goto cleanup;
  }
  executable = turtles_darwin_find_executable(argv[0]);
  if (executable == NULL) {
    error_number = errno;
    goto cleanup;
  }
  if (pipe(exec_pipe) < 0) {
    error_number = errno;
    goto cleanup;
  }
  int flags = fcntl(exec_pipe[1], F_GETFD);
  if (flags < 0 || fcntl(exec_pipe[1], F_SETFD, flags | FD_CLOEXEC) < 0) {
    error_number = errno;
    goto cleanup;
  }

  struct timespec started;
  if (clock_gettime(CLOCK_MONOTONIC, &started) < 0) {
    error_number = errno;
    goto cleanup;
  }
  struct timespec deadline = started;
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }

  /* MoonBit's async runtime blocks these signals on its worker thread. The
   * supervisor owns their disposition while active, so unblock them only
   * after installing handlers and preparing all parent-side launch state. */
  mask_error = pthread_sigmask(SIG_UNBLOCK, &watched_signals, NULL);
  if (mask_error != 0) {
    error_number = mask_error;
    goto cleanup;
  }

  if (turtles_darwin_interrupted != 0) {
    result = -3;
    goto cleanup;
  }

  child = fork();
  if (child < 0) {
    error_number = errno;
    goto cleanup;
  }
  if (child == 0) {
    close(exec_pipe[0]);
    if (sigaction(SIGTERM, &default_action, NULL) < 0 ||
        sigaction(SIGINT, &default_action, NULL) < 0 ||
        sigaction(SIGHUP, &default_action, NULL) < 0 ||
        setpgid(0, 0) < 0) {
      int child_error = errno;
      (void)write(exec_pipe[1], &child_error, sizeof(child_error));
      _exit(125);
    }
    execve(executable, argv, environ);
    int child_error = errno;
    (void)write(exec_pipe[1], &child_error, sizeof(child_error));
    _exit(127);
  }

  close(exec_pipe[1]);
  exec_pipe[1] = -1;

  if (setpgid(child, child) == 0 || errno == EACCES) {
    /* EACCES means exec already happened, after the child's own setpgid. */
    child_group_ready = true;
  } else if (getpgid(child) == child) {
    child_group_ready = true;
  }
  int exec_flags = fcntl(exec_pipe[0], F_GETFL);
  if (exec_flags < 0 || fcntl(exec_pipe[0], F_SETFL, exec_flags | O_NONBLOCK) < 0) {
    error_number = errno;
    goto child_cleanup;
  }
  int exec_error = 0;
  int exec_status = turtles_darwin_wait_for_exec(
    exec_pipe[0],
    child,
    &child_group_ready,
    &deadline,
    &exec_error);
  close(exec_pipe[0]);
  exec_pipe[0] = -1;
  if (exec_status == 0) {
    (void)dprintf(
      STDERR_FILENO,
      "[turtles:darwin-supervisor] could not start command %s: %s\n",
      argv[0],
      strerror(exec_error));
    result = 127;
    child_exec_failed = true;
    goto child_cleanup;
  }
  if (exec_status == -2) {
    result = -3;
    goto child_cleanup;
  }
  if (exec_status == -3) {
    result = -2;
    goto child_cleanup;
  }
  if (exec_status != 1) {
    error_number = EIO;
    goto child_cleanup;
  }
  if (turtles_darwin_interrupted != 0) {
    result = -3;
    goto child_cleanup;
  }

  for (;;) {
    siginfo_t child_info;
    int exited = turtles_darwin_wait_for_exit(child, &child_info);
    if (exited < 0) {
      error_number = errno;
      goto child_cleanup;
    }
    if (exited == 1) {
      if (turtles_darwin_interrupted != 0) {
        result = -3;
        goto child_cleanup;
      }
      if (turtles_darwin_reap(child, &child_status) < 0) {
        error_number = errno;
        goto child_cleanup;
      }
      child_reaped = true;
      result = turtles_darwin_status_from_siginfo(&child_info);
      goto cleanup;
    }
    if (turtles_darwin_interrupted != 0) {
      result = -3;
      goto child_cleanup;
    }
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
      error_number = errno;
      goto child_cleanup;
    }
    if (now.tv_sec > deadline.tv_sec ||
        (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec)) {
      result = -2;
      goto child_cleanup;
    }
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000L };
    while (nanosleep(&pause, &pause) < 0 && errno == EINTR) {
      if (turtles_darwin_interrupted != 0)
        break;
    }
  }

child_cleanup:
  if (child > 0 && !child_reaped) {
    if (child_exec_failed) {
      /* The child can only fail before exec after setpgid; it has not had a
       * chance to create descendants, so reap it without targeting a PGID
       * that may already have disappeared or been reused. */
      if (turtles_darwin_reap_bounded(child, &child_status, &child_reaped) < 0) {
        error_number = errno;
        result = -1;
      }
    } else if (!child_group_ready && getpgid(child) == child) {
      child_group_ready = true;
    }
    if (!child_exec_failed && child_group_ready) {
      int cleanup_error = turtles_darwin_kill_group_and_reap(
        child,
        &child_status,
        &child_reaped);
      if (cleanup_error < 0) {
        error_number = errno == 0 ? ECHILD : errno;
        result = -1;
      }
    } else if (!child_exec_failed) {
      (void)kill(child, SIGKILL);
      if (turtles_darwin_reap_bounded(child, &child_status, &child_reaped) < 0) {
        error_number = errno;
        result = -1;
      }
    }
  }

cleanup:
  if (exec_pipe[0] >= 0)
    close(exec_pipe[0]);
  if (exec_pipe[1] >= 0)
    close(exec_pipe[1]);
  turtles_darwin_free_argv(argv);
  free(executable);
  if (signal_mask_saved) {
    mask_error = pthread_sigmask(SIG_BLOCK, &watched_signals, NULL);
    if (mask_error != 0 && error_number == 0)
      error_number = mask_error;
  }
  if (turtles_darwin_interrupted != 0 && result >= 0)
    result = -3;
  if (hup_installed)
    turtles_darwin_restore_handler(SIGHUP, &old_hup);
  if (int_installed)
    turtles_darwin_restore_handler(SIGINT, &old_int);
  if (term_installed)
    turtles_darwin_restore_handler(SIGTERM, &old_term);
  if (signal_mask_saved) {
    mask_error = pthread_sigmask(SIG_SETMASK, &previous_signal_mask, NULL);
    if (mask_error != 0 && error_number == 0)
      error_number = mask_error;
  }
  if (error_number != 0) {
    (void)dprintf(
      STDERR_FILENO,
      "[turtles:darwin-supervisor] process-group cleanup failed: %s\n",
      strerror(error_number));
    result = -1;
  }
  return result;
}

#else

int32_t turtles_is_darwin(void) {
  return 0;
}

moonbit_string_t turtles_darwin_executable_path(void) {
  return moonbit_make_string_raw(0);
}

int32_t turtles_darwin_supervise(int32_t timeout_ms, moonbit_bytes_t packed) {
  (void)timeout_ms;
  (void)packed;
  return -1;
}

#endif
