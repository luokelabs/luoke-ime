#!/usr/bin/env python3
"""测试页的本机小服务：提供 page.html，并接收页面自己报告的输入框状态，写到 results/page-state.json。
浏览器（尤其是 Chrome）不一定响应辅助功能查询，所以让页面自己报告。只监听 127.0.0.1。"""
import http.server, json, os, sys, threading

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "results", "page-state.json")
lock = threading.Lock()
last = {"page": None, "seq": -1}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=HERE, **k)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")  # 浏览器别用缓存里的旧测试页
        super().end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            m = json.loads(body)
            page, seq = m.get("page"), m.get("seq", 0)
        except ValueError:
            page, seq = None, 0
        with lock:
            # 第一份报告来自刚加载的页面：之后只认它（之前测试留下的标签页也在报告）；同一页只接受更新的报告
            if seq == 1:
                last["page"] = page
            elif page != last["page"] or seq <= last["seq"]:
                self.send_response(204); self.end_headers(); return
            last["seq"] = seq
            tmp = STATE + ".tmp"
            with open(tmp, "wb") as f:
                f.write(body)
            os.replace(tmp, STATE)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass

os.makedirs(os.path.dirname(STATE), exist_ok=True)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Handler).serve_forever()
