/*
 * foa_pty.c —— FOA 无 Java-PTY 的伪终端桥（Android bionic，无需 NDK 之外的依赖）
 *
 * 背景
 * ----
 * Android/JVM 没有 pty API：ProcessBuilder 只能给「单向管道」，
 * 拿不到 tty，`vim` / `top` / `apt` 的进度条、Ctrl+C、方向键历史、
 * tab 补全全部失效。JNI 也没有暴露 posix_openpt。
 *
 * 但 bionic 自 API 23 起提供 posix_openpt/grantpt/unlockpt/ptsname，
 * NDK 的 <pty.h> 进一步提供 openpty()。于是：
 *   用 C 写一个极薄的中继器，把「Java 的管道」与「真正的 pty」接起来。
 *
 * 用法（由 MainActivity 以 ProcessBuilder 启动）
 * --------------------------------------------
 *   foa_pty <rows> <cols> <cmd> [args...]
 *
 * 环境变量
 *   FOA_PTY_SIZE_FILE  可选。指向一个文本文件，内容 "<rows> <cols>"。
 *                      主循环每 200ms 检查一次，变化即 ioctl(TIOCSWINSZ)，
 *                      使全屏程序（vim/top）随屏幕旋转/拖动重排。
 *
 * 行为
 * ----
 *   - openpty() 得到 master/slave；
 *   - SlavePath = ptsname(master)；
 *   - fork()；子进程 setsid() + TIOCSCTTY 抢控制终端，把
 *     slave 复制到 0/1/2，关闭 master，execvp(cmd)；
 *   - 父进程（本 shim）成为纯中继：
 *       本进程 stdin  → pty master    （键盘输入）
 *       pty master    → 本进程 stdout  （屏幕输出）
 *   - 本进程 stdin 的每一行首字节若为控制序列，需由调用方保证原样透传；
 *     shim 不做任何行编辑/回显处理（那是 tty 层与 readline 的职责）。
 *
 * 为什么 stdin 走「原始透传」
 * --------------------------
 *   调用方（Java）需要把用户按键**即时**写进本进程 stdin。
 *   为了让 Ctrl+C(0x03)、Ctrl+D(0x04)、ESC 序列不被本进程的
 *   stdio 行缓冲吞掉，进入中继前用 tcsetattr 把**本进程 stdin**
 *   设为 raw（等价 tcsetattr(STDIN_FILENO, TCSANOW, &raw)）。
 *   注意：本进程 stdin 是 Java 给的**管道**，不是 tty，
 *   tcsetattr 会 ENOTTY —— 因此真正防止缓冲的是：
 *   Java 侧每次 write 后立即 flush + 只按字节写。
 *   本 shim 自身用 read(2)/write(2) 裸系统调用，**绕开 stdio 缓冲**。
 *
 * 退出
 * ----
 *   子进程退出后，父进程把剩余输出读净，waitpid 取得真实退出码并
 *   以该码退出，供 Java 侧判断。
 *
 * 许可证：随 FOA 主工程（见仓库 LICENSE）。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define BUF 8192

/*
 * 窗口尺寸热更新（TIOCSWINSZ）走「控制文件」通道。
 * -----
 * 中继进程的 master fd 只在本进程手里，外部（Java）改不了它的 winsize；
 * 而 ProcessBuilder 只能给 0/1/2 三个标准流，没有额外的 fd 可用。
 * 折中方案：主循环的 poll 带 200ms 超时，每次超时检查环境变量
 * FOA_PTY_SIZE_FILE 指向的文件；内容为 "<rows> <cols>" 时即施加。
 *
 * 为什么不用 SIGWINCH 或 stdin 内联控制序列：
 *   - SIGWINCH 只有在 winsize 真的变了才由内核发给前台组，而改 winsize
 *     本身就要先拿到 master fd —— 鸡生蛋问题；
 *   - stdin 内联控制序列会被 shell/readline 当成用户输入，污染命令行。
 * 200ms 的检查间隔对「用户拖动/旋转屏幕后重排」完全够用（远小于人眼
 * 感知阈值），且空闲时开销只是每 200ms 一次 stat(2)。
 */
static void maybe_apply_size(int master, const char *size_file, int *last_r,
                             int *last_c) {
  if (!size_file || !*size_file) return;
  FILE *f = fopen(size_file, "r");
  if (!f) return;
  int r = 0, c = 0;
  int got = fscanf(f, "%d %d", &r, &c);
  fclose(f);
  if (got != 2) return;
  if (r < 5 || r > 500 || c < 20 || c > 1000) return;
  if (r == *last_r && c == *last_c) return;
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)r;
  ws.ws_col = (unsigned short)c;
  if (ioctl(master, TIOCSWINSZ, &ws) == 0) {
    *last_r = r;
    *last_c = c;
  }
}

/* 全局，信号处理里用来唤醒父进程中继循环 */
static volatile sig_atomic_t g_child_gone = 0;
static pid_t g_child = -1;

static void on_sigchld(int sig) {
  (void)sig;
  g_child_gone = 1;
}

static int set_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0) return -1;
  return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* 把 master 的窗口尺寸告知内核（影响 SIGWINCH 与全屏程序布局） */
static void apply_winsize(int master, int rows, int cols) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
  ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
  ioctl(master, TIOCSWINSZ, &ws);
}

/*
 * 子进程路径：抢控制终端后 exec。
 * 失败一律 _exit(127)，父进程据此报「无法执行」。
 */
static void child_exec(int master, int slave, char **argv) {
  /* 新会话：成为会话首进程，才能 acquire 控制终端 */
  if (setsid() < 0) _exit(120);

  /*
   * Ctrl+C 能不能生效，全看下面几步。setsid() 之后本进程已是新会话
   * 首进程，pgid 自动等于 pid（新进程组也一并建立了），**无需再
   * setpgid**——会话首进程调用 setpgid 会返回 EPERM（实测踩过：
   * 误判为致命错误 _exit(120)，表现为启动即退出）。
   *
   * 但只有 setsid 还不够：tty 行规则收到 VINTR(0x03) 后要找
   * 「本会话的前台进程组」投递 SIGINT，这个登记动作必须显式做，
   * 否则信号石沉大海（实测现象：屏幕回显 ^C 但 sleep 继续睡）。
   *
   * 因此：
   *   1) setsid()            —— 新会话，pgid == pid；
   *   2) ioctl(TIOCSCTTY)    —— slave 成为本会话控制终端；
   *   3) tcsetpgrp(slave, getpgrp()) —— 登记前台进程组。
   * 做完这三步，VINTR / VQUIT / VSUSP 才有明确的投递目标。
   */
  ioctl(slave, TIOCSCTTY, 1);

  if (tcsetpgrp(slave, getpgrp()) < 0) {
    /*
     * 非致命：个别内核/容器下会失败，退化为「无前台组」，
     * 表现是 Ctrl+C 无效但交互仍可用。不因此拒绝启动。
     */
  }

  dup2(slave, STDIN_FILENO);
  dup2(slave, STDOUT_FILENO);
  dup2(slave, STDERR_FILENO);
  /* 清掉父进程继承的屏蔽集，否则 SIGINT 会被静默丢弃 */
  sigset_t empty;
  sigemptyset(&empty);
  sigprocmask(SIG_SETMASK, &empty, NULL);
  if (slave > 2) close(slave);
  if (master > 2) close(master);

  execvp(argv[0], argv);
  /* exec 失败：给个可辨识的退出码，父进程直接上报 127 */
  _exit(127);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: foa_pty <rows> <cols> <cmd> [args...]\n");
    return 64;
  }

  int rows = atoi(argv[1]);
  int cols = atoi(argv[2]);
  char **cmd = &argv[3];

  int master = -1, slave = -1;
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
  ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);

  /*
   * 默认 termios：ONLCR 让内核把 \n 补成 \r\n（否则输出锯齿），
   * ECHO 打开让 shell 自己回显用户输入，ICANON 支持行编辑。
   * 这一层是「真 tty」体验的来源，别关。
   *
   * ⚠️ 必须先 memset 再**显式填 c_cc 控制字符数组**，不能只设 flag。
   * 踩过的坑：只设 c_iflag/c_oflag/c_cflag/c_lflag 而 c_cc 全零，
   * `stty -a` 会显示 `intr = <undef>; erase = <undef>; ...` 全部未定义，
   * 于是 isig 虽开着、内核也认不出哪个字节是 Ctrl+C，按键被当成普通
   * 字符送进 shell —— 实测现象是屏幕回显 ^C 但 sleep 照睡不误。
   * 这里按 POSIX 传统值逐个赋值（与 Linux/Android 默认一致）。
   */
  struct termios tio;
  memset(&tio, 0, sizeof(tio));
  tio.c_iflag = ICRNL | IXON;
  tio.c_oflag = OPOST | ONLCR;
  tio.c_cflag = CS8 | CREAD | CLOCAL;
  tio.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;

  tio.c_cc[VINTR] = 0x03;   /* Ctrl+C  → SIGINT  */
  tio.c_cc[VQUIT] = 0x1c;   /* Ctrl+\  → SIGQUIT */
  tio.c_cc[VSUSP] = 0x1a;   /* Ctrl+Z  → SIGTSTP */
  tio.c_cc[VERASE] = 0x7f;  /* DEL     → 退格    */
  tio.c_cc[VKILL] = 0x15;   /* Ctrl+U  → 删整行  */
  tio.c_cc[VEOF] = 0x04;    /* Ctrl+D  → EOF     */
  tio.c_cc[VWERASE] = 0x17; /* Ctrl+W  → 删词    */
  tio.c_cc[VLNEXT] = 0x16;  /* Ctrl+V  → 字面量  */
  tio.c_cc[VSTART] = 0x11;  /* Ctrl+Q  → 恢复输出 */
  tio.c_cc[VSTOP] = 0x13;   /* Ctrl+S  → 暂停输出 */
  tio.c_cc[VMIN] = 1;
  tio.c_cc[VTIME] = 0;

  if (openpty(&master, &slave, NULL, &tio, &ws) != 0) {
    fprintf(stderr, "openpty failed: %s\n", strerror(errno));
    return 71;
  }

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_sigchld;
  sigaction(SIGCHLD, &sa, NULL);

  /*
   * 中继进程必须免疫终端信号。
   * 子进程通过 tcsetpgrp 拿到了前台组身份，用户按 Ctrl+C 时内核会把
   * SIGINT 发给「前台进程组」——正常只打到子进程。但 shim 在成为
   * 纯中继前可能短暂处于前台组，或某些场景下内核按终端粒度投递，
   * 一旦 shim 被 SIGINT 打死，用户看到的就是「按一下 Ctrl+C 整个
   * 终端进程退出」（实测：BrokenPipeError）。所以这里显式忽略。
   * SIGPIPE 同理：用户关终端时不要因写管道失败而死。
   */
  signal(SIGINT, SIG_IGN);
  signal(SIGQUIT, SIG_IGN);
  signal(SIGTSTP, SIG_IGN);
  signal(SIGTTIN, SIG_IGN);
  signal(SIGTTOU, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);

  g_child = fork();
  if (g_child < 0) {
    fprintf(stderr, "fork failed: %s\n", strerror(errno));
    return 71;
  }
  if (g_child == 0) {
    child_exec(master, slave, cmd);
    /* not reached */
  }

  /*
   * ⚠️ 此处**不能** setpgid(child, child)。
   * 一旦父进程把子进程设成进程组组长，子进程随后的 setsid() 就会
   * 失败（POSIX：进程组组长不得成为新会话首进程），实测表现为
   * 退出码 120、终端一启动就退出。
   * 子进程的会话与进程组完全由它自己 setsid() 建立，父进程不插手。
   */
  (void)0;

  close(slave); /* 父进程只持 master */

  apply_winsize(master, rows, cols);

  /* 非阻塞 master，便于与 stdin 一起 poll */
  set_nonblock(master);
  set_nonblock(STDIN_FILENO);

  char buf[BUF];
  int master_eof = 0;
  int stdin_open = 1;
  const char *size_file = getenv("FOA_PTY_SIZE_FILE");
  int last_r = rows > 0 ? rows : 24;
  int last_c = cols > 0 ? cols : 80;

  while (!master_eof && !g_child_gone) {
    struct pollfd pfd[2];
    nfds_t nfds = 1;
    /* poll(2) 被 SIGCHLD 中断会返回 -1/EINTR，循环重新检查 g_child_gone */
    if (stdin_open) {
      pfd[0].fd = STDIN_FILENO;
      pfd[0].events = POLLIN;
      pfd[0].revents = 0;
      nfds = 2;
    }
    pfd[nfds - 1].fd = master;
    pfd[nfds - 1].events = POLLIN;
    pfd[nfds - 1].revents = 0;

    /* 200ms 超时：兼顾响应速度与空转开销（见 maybe_apply_size 注释） */
    int pr = poll(pfd, nfds, 200);
    if (pr < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (pr == 0) {
      /* 纯超时：只做尺寸检查，不读写 */
      maybe_apply_size(master, size_file, &last_r, &last_c);
      continue;
    }
    maybe_apply_size(master, size_file, &last_r, &last_c);

    /* ---- 键盘 → pty ---- */
    if (stdin_open && (pfd[0].revents & (POLLIN | POLLHUP))) {
      ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
      if (n > 0) {
        ssize_t off = 0;
        while (off < n) {
          ssize_t w = write(master, buf + off, (size_t)(n - off));
          if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { poll(NULL, 0, 5); continue; }
            goto done;
          }
          off += w;
        }
      } else if (n == 0) {
        /*
         * 调用方关闭了 stdin：不再有键盘输入，但子进程可能仍在跑。
         * 置 stdin_open=false，主循环退化成「只读 master」，
         * 直到子进程退出（g_child_gone）或 master EOF。
         */
        stdin_open = 0;
      }
    }

    /* ---- pty → 屏幕 ---- */
    if (pfd[nfds - 1].revents & (POLLIN | POLLHUP)) {
      ssize_t m = read(master, buf, sizeof(buf));
      if (m > 0) {
        ssize_t off = 0;
        while (off < m) {
          ssize_t w = write(STDOUT_FILENO, buf + off, (size_t)(m - off));
          if (w < 0) {
            if (errno == EINTR) continue;
            goto done;
          }
          off += w;
        }
      } else if (m == 0) {
        master_eof = 1;
      } else if (errno != EAGAIN && errno != EINTR) {
        master_eof = 1;
      }
    }
  }

done:
  /* 把 master 里残余输出读净（子进程可能刚写完后立刻退出） */
  for (int guard = 0; guard < 1000 && !master_eof; guard++) {
    ssize_t m = read(master, buf, sizeof(buf));
    if (m > 0) {
      ssize_t off = 0;
      while (off < m) {
        ssize_t w = write(STDOUT_FILENO, buf + off, (size_t)(m - off));
        if (w < 0) {
          if (errno == EINTR) continue;
          break;
        }
        off += w;
      }
      continue;
    }
    if (m == 0) break;
    if (errno == EAGAIN) { poll(NULL, 0, 10); continue; }
    break;
  }

  int status = 0;
  pid_t got = waitpid(g_child, &status, 0);
  close(master);

  if (got < 0) return 70;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 70;
}
