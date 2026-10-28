#!/usr/bin/python3
"""一次性本机监听器（在沙盒外运行）。打印 JSON 一行: {"tcp4":port,"tcp6":port,"unix":path,"udp4":port}
任何 TCP 连接回 "HTTP/1.0 200 OK ... luoke-probe-ok"；并把收到的字节数记到 stderr。
用法: listener.py UNIX_SOCKET_PATH [--lan]   (运行直到被 kill)"""
import json, os, socket, sys, threading

def serve_tcp(sock):
    while True:
        try:
            c, _ = sock.accept()
        except OSError:
            return
        try:
            c.settimeout(1.0)
            try: c.recv(4096)
            except Exception: pass
            c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nluoke-probe-ok")
        finally:
            c.close()

def serve_udp(sock):
    while True:
        try:
            data, addr = sock.recvfrom(4096)
            sock.sendto(b"luoke-probe-ok", addr)
        except OSError:
            return

def main():
    unix_path = sys.argv[1]
    out = {}
    s4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s4.bind(("127.0.0.1", 0)); s4.listen(16)
    out["tcp4"] = s4.getsockname()[1]; threading.Thread(target=serve_tcp, args=(s4,), daemon=True).start()
    try:
        s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s6.bind(("::1", 0)); s6.listen(16)
        out["tcp6"] = s6.getsockname()[1]; threading.Thread(target=serve_tcp, args=(s6,), daemon=True).start()
    except OSError:
        pass
    if os.path.exists(unix_path): os.unlink(unix_path)
    su = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); su.bind(unix_path); su.listen(16)
    out["unix"] = unix_path; threading.Thread(target=serve_tcp, args=(su,), daemon=True).start()
    u4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u4.bind(("127.0.0.1", 0))
    out["udp4"] = u4.getsockname()[1]; threading.Thread(target=serve_udp, args=(u4,), daemon=True).start()
    if "--lan" in sys.argv:   # 额外绑 0.0.0.0，用来验证 "local" 不放行本机的非回环地址
        sa = socket.socket(socket.AF_INET, socket.SOCK_STREAM); sa.bind(("0.0.0.0", 0)); sa.listen(16)
        out["tcp4_any"] = sa.getsockname()[1]; threading.Thread(target=serve_tcp, args=(sa,), daemon=True).start()
    print(json.dumps(out), flush=True)
    threading.Event().wait()

main()
