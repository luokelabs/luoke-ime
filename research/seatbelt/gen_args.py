#!/usr/bin/python3
"""gen_args: 引擎说明里的 permissions  ->  sandbox-exec 的命令行参数 + 引擎环境变量（给壳的 Swift 实现做参照）。

profile.sb 是唯一的模板；"每条声明一个小片段"在这里就是几个 -D 参数：
    permissions.network = "none"|"local"|"any"   ->  -D NET=...
    permissions.network_ports = [11434, ...]     ->  -D LOCAL_PORT_0=11434 ...   (本文提出的扩展，仅 local 档有意义)
    permissions.write   = ["~/Documents/x", ...]  ->  -D WRITE_0=<realpath> ...    (最多 16 条)
    permissions.microphone / camera / screen      ->  -D MIC=1 / CAM=1 / SCREEN=1
没有任何一条规则需要"生成 profile 文本"；唯一的变长列表（额外可写路径、本机端口）用编号槽位。

用法:
    gen_args.py --demo                       打印几个示例（none / local / any / 额外写路径 / 麦克风）
    from gen_args import sandbox_command     作为库使用
"""
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILE = os.path.join(HERE, "profile.sb")
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
MAX_WRITES = 16
MAX_PORTS = 8


class PermissionError_(ValueError):
    pass


def real(path, home):
    """~ 展开 + 绝对化 + 解析符号链接（对还不存在的末级路径，解析其父目录）。Seatbelt 按真实路径匹配，必须这样做。"""
    p = os.path.expanduser(path.replace("~", home, 1) if path.startswith("~") else path)
    if not os.path.isabs(p):
        raise PermissionError_("路径必须是绝对路径或以 ~ 开头: %r" % path)
    p = os.path.normpath(p)
    if p == "/":
        raise PermissionError_("不允许声明根目录可写")
    head, tail = os.path.split(p)
    if os.path.lexists(p):
        return os.path.realpath(p)
    return os.path.join(os.path.realpath(head), tail)


def user_temp_dir():
    out = subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
    return os.path.realpath(out) + "/"


def sandbox_command(engine_id, engine_dir, data_dir, tmp_dir, permissions=None, home=None, data_root=None, profile=PROFILE):
    """返回 (argv_prefix, env, warnings)。argv = argv_prefix + 引擎的 run 命令；cwd = engine_dir；env 并入引擎的环境。"""
    permissions = permissions or {}
    home = os.path.realpath(home or os.path.expanduser("~"))
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", engine_id):
        raise PermissionError_("引擎标识只能含 [A-Za-z0-9._-]: %r" % engine_id)
    net = permissions.get("network", "none")
    if net not in ("none", "local", "any"):
        raise PermissionError_('network 只能是 "none" / "local" / "any": %r' % net)
    ports = permissions.get("network_ports", [])
    if ports and net != "local":
        raise PermissionError_("network_ports 只在 network=local 时有意义")
    if len(ports) > MAX_PORTS or not all(isinstance(p, int) and 0 < p < 65536 for p in ports):
        raise PermissionError_("network_ports 最多 %d 个、范围 1-65535" % MAX_PORTS)
    writes = [real(p, home) for p in permissions.get("write", [])]
    if len(writes) > MAX_WRITES:
        raise PermissionError_("write 最多 %d 条" % MAX_WRITES)
    engine_dir, data_dir, tmp_dir = (os.path.realpath(x) for x in (engine_dir, data_dir, tmp_dir))
    warnings = []
    for w in writes:
        if w == home or home.startswith(w + "/"):
            warnings.append("write 声明了整个家目录（或其上级）: %s —— 安装确认时要用红色字提示用户" % w)
        if engine_dir.startswith(w + "/") or engine_dir == w:
            warnings.append("write 覆盖了引擎文件夹本身: %s —— profile 的收尾 deny 仍会保持只读" % w)
    a = [SANDBOX_EXEC, "-f", profile,
         "-D", "ENGINE_ID=" + engine_id, "-D", "ENGINE_DIR=" + engine_dir,
         "-D", "DATA_DIR=" + data_dir, "-D", "TMP_DIR=" + tmp_dir,
         "-D", "NET=" + net,
         "-D", "MIC=%d" % bool(permissions.get("microphone")),
         "-D", "CAM=%d" % bool(permissions.get("camera")),
         "-D", "SCREEN=%d" % bool(permissions.get("screen")),
         "-D", "USER_TMP=" + user_temp_dir(), "-D", "HOME=" + home]
    if data_root:
        a += ["-D", "DATA_ROOT=" + os.path.realpath(data_root)]
    for i, p in enumerate(writes):
        a += ["-D", "WRITE_%d=%s" % (i, p)]
    for i, p in enumerate(ports):
        a += ["-D", "LOCAL_PORT_%d=%d" % (i, p)]
    env = {
        "TMPDIR": tmp_dir + "/",                              # Python tempfile / Node os.tmpdir() / 多数运行时认这个
        "LUOKE_IME_DATA": data_dir,
        "PYTHONPYCACHEPREFIX": os.path.join(data_dir, "pycache"),  # Python 字节码缓存落在自己的数据目录（见 README）
    }
    return a, env, warnings


def _demo():
    import tempfile
    import shutil
    root = os.path.realpath(tempfile.mkdtemp(prefix="luoke-demo-"))
    eng, dat, tmp = root + "/engines/demo", root + "/data/demo", root + "/tmp/demo"
    for d in (eng, dat, tmp):
        os.makedirs(d)
    examples = [
        ("不声明任何权限（network 缺省 none）", {}),
        ('network: "none"', {"network": "none"}),
        ('network: "local"', {"network": "local"}),
        ('network: "local" + 端口白名单（本文提出的扩展）', {"network": "local", "network_ports": [11434]}),
        ('network: "any"', {"network": "any"}),
        ("额外写路径", {"write": ["~/Documents/luoke-demo"]}),
        ("麦克风", {"microphone": True}),
        ("麦克风 + 联网 + 额外写路径", {"microphone": True, "network": "any", "write": ["~/Library/Caches/demo"]}),
    ]
    fixed = "-D ENGINE_ID=demo -D ENGINE_DIR=<引擎文件夹> -D DATA_DIR=<数据目录> -D TMP_DIR=<临时目录> -D USER_TMP=<...> -D HOME=<...> -D DATA_ROOT=<...>"
    for title, perm in examples:
        argv, env, warn = sandbox_command("demo", eng, dat, tmp, perm, data_root=root + "/data")
        delta = []
        for i, x in enumerate(argv):
            if x == "-D" and re.match(r"(NET|MIC|CAM|SCREEN|WRITE_\d+|LOCAL_PORT_\d+)=", argv[i + 1]):
                delta.append("-D " + shlex.quote(argv[i + 1]))
        print("# %s   permissions=%s" % (title, json.dumps(perm, ensure_ascii=False)))
        print("  sandbox-exec -f profile.sb  [固定: %s]  %s  <run命令...>" % (fixed, " ".join(delta)))
    print("\n# 每个引擎都加的环境变量（路径随引擎而变）:")
    print("  " + json.dumps({k: v.replace(root, "<ROOT>") for k, v in env.items()}, ensure_ascii=False, indent=2).replace("\n", "\n  "))
    shutil.rmtree(root)


if __name__ == "__main__":
    if "--demo" in sys.argv:
        _demo()
    else:
        print(__doc__)
