// sbprobe: 只读地问"当前进程的沙盒 profile 允许不允许做 X"，不会真的去做 X，更不会弹窗。
//   sbprobe check OP [TYPE NAME]   sandbox_check(): 只让内核按 profile 求值（带 NO_REPORT，不产生日志）。
//                                   TYPE: path|global|local|appleevent|pref|sysctl|notification
//   sbprobe lookup NAME...         bootstrap_look_up(): 只拿一个 send right，不发任何消息。
//                                   kr=0 放行且服务存在；1100 被沙盒拒绝；1102 服务不存在
//   sbprobe connect-unix PATH      只 connect() 再 close()，不发数据
// 输出每个目标一行 JSON。
// 注: sandbox_check 是可变参数函数，Apple Silicon 上可变参数走栈，Python ctypes 传不对，所以用 C。
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
#define NO_REPORT 0x40000000

static int type_of(const char *t) {
    if (!strcmp(t, "path")) return 1;
    if (!strcmp(t, "global")) return 2;
    if (!strcmp(t, "local")) return 3;
    if (!strcmp(t, "appleevent")) return 4;
    if (!strcmp(t, "right")) return 5;
    if (!strcmp(t, "pref")) return 6;
    if (!strcmp(t, "kext")) return 7;
    if (!strcmp(t, "sysctl")) return 8;
    if (!strcmp(t, "notification")) return 9;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage\n"); return 2; }
    if (!strcmp(argv[1], "check")) {
        int rc;
        if (argc >= 5) rc = sandbox_check(getpid(), argv[2], type_of(argv[3]) | NO_REPORT, argv[4]);
        else rc = sandbox_check(getpid(), argv[2], NO_REPORT);
        printf("{\"probe\":\"check\",\"op\":\"%s\",\"name\":\"%s\",\"rc\":%d,\"allowed\":%s}\n",
               argv[2], argc >= 5 ? argv[4] : "", rc, rc == 0 ? "true" : "false");
    } else if (!strcmp(argv[1], "lookup")) {
        for (int i = 2; i < argc; i++) {
            mach_port_t p = MACH_PORT_NULL;
            kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[i], &p);
            printf("{\"probe\":\"lookup\",\"name\":\"%s\",\"kr\":%d,\"ok\":%s}\n", argv[i], kr, kr == 0 ? "true" : "false");
        }
    } else if (!strcmp(argv[1], "connect-unix")) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX; strncpy(a.sun_path, argv[2], sizeof a.sun_path - 1);
        int rc = connect(fd, (struct sockaddr *)&a, sizeof a);
        printf("{\"probe\":\"connect-unix\",\"path\":\"%s\",\"ok\":%s}\n", argv[2], rc == 0 ? "true" : "false");
        close(fd);
    }
    return 0;
}
