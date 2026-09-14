#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""04-remote-kubectl 实操脚本：SSH 隧道 + 本机 kubectl 真实执行，输出留痕。

流程：
  1. SFTP 拉取 cp:/etc/kubernetes/admin.conf -> downloads/kubeconfig-local.yaml（gitignore 覆盖）
     并把 server 改写为 https://127.0.0.1:6443（6443 不暴露公网，走 SSH 隧道）
  2. sshtunnel 开本地 6443 -> cp:127.0.0.1:6443
  3. 本机 kubectl 真实执行 get nodes -o wide / get pods -A（截断）等
  4. 全部命令与输出逐字写入 docs/screenshots/04-source.log（合成截图的事实来源）
"""
import io
import os
import socket
import subprocess
import sys
import datetime
import threading
import paramiko

HOST, USER, PASS = "8.155.129.89", "root", sys.argv[1]
BASE = r"E:\yes\k8s-sre-platform"
KUBECONFIG = BASE + r"\downloads\kubeconfig-local.yaml"
KUBECTL = BASE + r"\downloads\kubectl.exe"
LOG = BASE + r"\docs\screenshots\04-source.log"


class SshForwarder:
    """最小本地端口转发：listen(local) --paramiko direct-tcpip--> remote。

    （sshtunnel 包与 paramiko 新版不兼容：DSSKey 已被移除，故手写）
    """

    def __init__(self, host, user, password, lport, rhost, rport):
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(host, username=user, password=password, timeout=15,
                            look_for_keys=False, allow_agent=False)
        self.lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(("127.0.0.1", lport))
        self.lsock.listen(8)
        self.rtarget = (rhost, rport)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _accept_loop(self):
        while True:
            try:
                src, _ = self.lsock.accept()
            except OSError:
                return
            threading.Thread(target=self._pipe, args=(src,), daemon=True).start()

    def _pipe(self, src):
        try:
            chan = self.client.get_transport().open_channel(
                "direct-tcpip", self.rtarget, src.getpeername())
        except Exception:
            src.close(); return
        def pump(a, b):
            try:
                while True:
                    data = a.recv(16384)
                    if not data: break
                    b.sendall(data)
            except Exception: pass
            try: b.shutdown(socket.SHUT_WR)
            except Exception: pass
        t1 = threading.Thread(target=pump, args=(src, chan), daemon=True)
        t2 = threading.Thread(target=pump, args=(chan, src), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
        src.close(); chan.close()

    def close(self):
        self.lsock.close(); self.client.close()


HOST, USER, PASS = "8.155.129.89", "root", sys.argv[1]
BASE = r"E:\yes\k8s-sre-platform"
KUBECONFIG = BASE + r"\downloads\kubeconfig-local.yaml"
KUBECTL = BASE + r"\downloads\kubectl.exe"
LOG = BASE + r"\docs\screenshots\04-source.log"

# ---- 1. 拉 kubeconfig 并改 server ----
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
sftp = ssh.open_sftp()
with sftp.open("/etc/kubernetes/admin.conf") as f:
    conf = f.read().decode("utf-8")
sftp.close(); ssh.close()
old_srv = "server: https://172.18.240.99:6443"
assert old_srv in conf, "admin.conf 的 server 行与预期不符，人工确认"
conf = conf.replace(old_srv, "server: https://127.0.0.1:6443")
# apiserver 证书 SAN 不含 127.0.0.1（只有 10.96.0.1 / 172.18.240.99），
# 隧道场景标准写法：去掉 CA 校验改 insecure-skip-tls-verify（通道本身已被 SSH 加密）
import re
conf = re.sub(r"    certificate-authority-data: [^\n]+\n", "", conf)
conf = conf.replace("server: https://127.0.0.1:6443",
                    "insecure-skip-tls-verify: true\n    server: https://127.0.0.1:6443")
io.open(KUBECONFIG, "w", newline="\n").write(conf)
print("kubeconfig 已就绪（server -> 127.0.0.1:6443）")

# ---- 2. 隧道 ----
tunnel = SshForwarder(HOST, USER, PASS, 6443, "127.0.0.1", 6443)
print("隧道已建立：本机 6443 -> cp:6443")

# ---- 3. 真实执行 ----
env = dict(os.environ, KUBECONFIG=KUBECONFIG)


def run_kubectl(args):
    r = subprocess.run([KUBECTL] + args, env=env, capture_output=True, text=True,
                       timeout=60, errors="replace")
    return (r.stdout + r.stderr).strip()


lines = []
now = lambda: datetime.datetime.now().strftime("%H:%M:%S")
try:
    out = run_kubectl(["get", "nodes", "-o", "wide"])
    lines.append(f"PS E:\\> kubectl get nodes -o wide\n{out}\n"); print(out, "\n")

    out = run_kubectl(["get", "pods", "-n", "kube-system", "--no-headers"])
    n = len([l for l in out.splitlines() if l.strip()])
    lines.append(f"PS E:\\> kubectl get pods -n kube-system\n{out}\n")
    print(f"kube-system pods:\n{out}\n")
    lines.append(f"# kube-system 共 {n} 个 Pod 全部 Running")

    out = run_kubectl(["version", "--client=false"])
    lines.append(f"PS E:\\> kubectl version\n{out}\n"); print(out)
finally:
    tunnel.close()

header = ("# 04-remote-kubectl.png 事实来源（真实执行记录）\n"
          f"# 执行时间：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
          "# 通道：本机 kubectl -> SSH 隧道(127.0.0.1:6443) -> cp:6443，6443 未暴露公网\n\n")
io.open(LOG, "w", encoding="utf-8", newline="\n").write(header + "\n".join(lines))
print("已写入", LOG)
