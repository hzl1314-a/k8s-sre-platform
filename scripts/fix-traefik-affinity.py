#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Traefik podAntiAffinity 修复上云 + 复验（chaos-drill.md 改进项 #5 闭环）

用法（本机执行，Windows / Git Bash 均可）：
    python scripts/fix-traefik-affinity.py <ssh_password>

做五件事（对应「发现 -> 修复 -> 复验」闭环的「修复 + 复验」）：
  1. SFTP 上传新版 manifests/ingress/traefik-values.yaml 到 cp:~/traefik-values.yaml（md5 校验）
  2. helm upgrade（chart 用 cp 上已有的 ~/traefik-41.5.0.tgz）
  3. 轮询等待 2/2 副本 Ready 且分落不同节点（required 反亲和的复验核心，超时 240s）
  4. 复验输出：pods -o wide / describe 的反亲和与容忍段 / 入口 200 探活
  5. 全程时间戳日志落盘 docs/traefik-affinity-fix.log

失败安全约定（沿用 alert-drill 的教训）：
  - 上传或 helm upgrade 失败 -> 直接退出，不做任何「猜测式」补救
  - 轮询超时 -> 只报告现场（get pods / describe / rollout status），不回滚、不删改
"""

import sys
import time
import hashlib
import datetime
import paramiko

HOST = "8.155.129.89"
USER = "root"
LOCAL_VALUES = "manifests/ingress/traefik-values.yaml"
REMOTE_VALUES = "traefik-values.yaml"
REMOTE_CHART_CANDIDATES = [
    "traefik-41.5.0.tgz",
    "downloads/traefik-41.5.0.tgz",
]
LOG_LINES = []


def log(msg):
    line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    LOG_LINES.append(line)


def run(ssh, cmd, timeout=120):
    """执行命令，返回 (exit_code, stdout, stderr)。不抛异常，由调用方判定。"""
    _, out, err = ssh.exec_command(cmd, timeout=timeout)
    rc = out.channel.recv_exit_status()
    return rc, out.read().decode("utf-8", "replace"), err.read().decode("utf-8", "replace")


def md5_local(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    password = sys.argv[1]

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=password, timeout=15,
                look_for_keys=False, allow_agent=False)
    log("SSH 已连接 cp 节点")

    # ---- 0. 前置现场确认：chart 在哪 + 当前副本分布（修复前基线） ----
    chart = None
    for cand in REMOTE_CHART_CANDIDATES:
        rc, out, _ = run(ssh, f"ls -la ~/{cand} 2>/dev/null")
        if rc == 0 and out.strip():
            chart = cand
            break
    if chart is None:
        log("!! 找不到 ~/traefik-41.5.0.tgz（两个候选路径都没有），先确认 chart 位置再重跑")
        sys.exit(1)

    rc, out, err = run(ssh, "kubectl -n traefik get pods -o wide --no-headers")
    log("修复前副本分布（基线）：")
    print(out, flush=True)
    LOG_LINES.extend(out.rstrip("\n").split("\n"))

    # ---- 1. SFTP 上传新 values + md5 校验 ----
    sftp = ssh.open_sftp()
    sftp.put(LOCAL_VALUES, REMOTE_VALUES)
    sftp.close()
    local_md5 = md5_local(LOCAL_VALUES)
    rc, out, _ = run(ssh, f"md5sum ~/{REMOTE_VALUES}")
    remote_md5 = out.split()[0] if out.split() else ""
    if local_md5 != remote_md5:
        log(f"!! md5 不符 local={local_md5} remote={remote_md5}，中止（不上 helm）")
        sys.exit(1)
    log(f"values 已上传并 md5 校验一致（{local_md5}）")

    # ---- 2. helm upgrade ----
    log("执行 helm upgrade ...")
    rc, out, err = run(ssh, f"helm upgrade traefik ~/{chart} -n traefik -f ~/{REMOTE_VALUES}",
                       timeout=300)
    log(f"helm upgrade 退出码 {rc}")
    if out.strip():
        LOG_LINES.extend(out.rstrip("\n").split("\n"))
        print(out, flush=True)
    if rc != 0:
        log(f"!! helm upgrade 失败：{err.strip()}")
        sys.exit(1)

    # ---- 3. 轮询复验：2/2 Ready + 分落不同节点 ----
    deadline = time.time() + 240
    ok = False
    while time.time() < deadline:
        rc, out, _ = run(ssh, ("kubectl -n traefik get pods -l app.kubernetes.io/name=traefik "
                               "-o jsonpath='{range .items[*]}{.metadata.name}{\" \"}"
                               "{.status.phase}{\" \"}{.spec.nodeName}{\"\\n\"}{end}'"))
        lines = [l for l in out.strip().split("\n") if l.strip()]
        running_nodes = [l.split()[2] for l in lines if len(l.split()) >= 3 and l.split()[1] == "Running"]
        n_running = len(running_nodes)
        n_distinct = len(set(running_nodes))
        log(f"轮询中：Running {n_running}/2，节点 {running_nodes}")
        if n_running == 2 and n_distinct == 2:
            ok = True
            break
        time.sleep(6)

    # ---- 4. 复验证据输出 ----
    rc, out, _ = run(ssh, "kubectl -n traefik get pods -o wide")
    log("修复后副本分布（复验）：")
    print(out, flush=True)
    LOG_LINES.extend(out.rstrip("\n").split("\n"))

    rc, out, _ = run(ssh, "kubectl -n traefik describe deploy traefik | grep -A8 -E 'Affinity|Tolerations'")
    log("Deployment 反亲和 / 容忍配置：")
    print(out, flush=True)
    LOG_LINES.extend(out.rstrip("\n").split("\n"))

    rc, out, _ = run(ssh, "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:30080/")
    code = out.strip()
    log(f"入口探活 http://127.0.0.1:30080/ -> {code}")

    if not ok:
        log("!! 240s 内未达到「2/2 Ready 且分落两节点」，请人工排查下面现场：")
        rc, out, _ = run(ssh, "kubectl -n traefik rollout status deploy/traefik --timeout=5s; "
                              "kubectl -n traefik get events --sort-by=.lastTimestamp | tail -15")
        print(out, flush=True)
        LOG_LINES.extend(out.rstrip("\n").split("\n"))
        ssh.close()
        write_log()
        sys.exit(1)

    log(f"复验结论：required 反亲和生效，双副本分落两节点；入口探活 {code} "
        f"{'✅（应为 200）' if code == '200' else '⚠️ 非 200，请检查'}")

    ssh.close()
    write_log()


def write_log():
    with open("docs/traefik-affinity-fix.log", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(LOG_LINES) + "\n")
    print("日志已落盘 docs/traefik-affinity-fix.log", flush=True)


if __name__ == "__main__":
    main()
