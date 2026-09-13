# 演练一：优雅排水 k8s-w1 全自动执行器
# 产出: docs/chaos-drill1-timeline.log（带时间戳事件线）+ docs/probe-drill1.log（可用性原始数据）
# 流程: SFTP 上传 probe 脚本 -> 起 10min 探测 -> 后台 drain -> 2s 轮询 pod 漂移/节点/告警计数
#       -> drain 完 uncordon -> 等 settle -> 收探针数据 -> 可用率统计
import paramiko, time, sys, io, datetime

HOST, USER, PASS = '8.155.129.89', 'root', sys.argv[1] if len(sys.argv) > 1 else ''
TLOG = r'E:/yes/k8s-sre-platform/docs/chaos-drill1-timeline.log'
PLOG = r'E:/yes/k8s-sre-platform/docs/probe-drill1.log'
AM = None  # alertmanager ClusterIP，连接后探测

t0 = None
logf = io.open(TLOG, 'w', encoding='utf-8', newline='\n')

def ts():
    return datetime.datetime.now().strftime('%H:%M:%S')

def emit(msg):
    line = f'[{ts()}] {msg}'
    print(line, flush=True)
    logf.write(line + '\n')
    logf.flush()

def rel():
    return f'T+{int(time.time() - t0)}s' if t0 else 'pre'

c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

def run(cmd, t=120):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode().strip() or e.read().decode().strip()

# ---- 0. 前置：上传探针脚本、探测 AM ClusterIP ----
sftp = c.open_sftp()
sftp.put(r'E:/yes/k8s-sre-platform/scripts/availability-probe.sh', '/root/availability-probe.sh')
sftp.close()
emit('probe 脚本已上传')
AM = run("kubectl -n monitoring get svc kube-prometheus-stack-alertmanager -o jsonpath='{.spec.clusterIP}'")
emit(f'Alertmanager ClusterIP = {AM}')
base_am = run("curl -s -m 5 " + AM + ":9093/metrics | grep -E '^alertmanager_notifications_total' | head -8")
emit('--- AM 通知计数基线 ---')
emit(base_am or '(无)')

# ---- 1. 演练前快照 ----
emit('--- 演练前快照 ---')
emit(run("kubectl get pods -n boutique -o wide --no-headers | awk '{print $1, $3, $7}'"))
emit('w1 上的监控组件: ' + run("kubectl get pods -n monitoring -o wide --no-headers | awk '$7==\"k8s-w1\" {print $1}'") or '(无)')

# ---- 2. 启动探针（10 分钟自限） ----
run("nohup bash /root/availability-probe.sh http://127.0.0.1:30080/ -d 600 -o /root/probe-drill1.log >/root/probe-drill1.out 2>&1 &")
time.sleep(2)
emit('探针已启动（600s 自限），输出 /root/probe-drill1.log')

# ---- 3. 发起 drain ----
emit('=== T0：发起 kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data ===')
t0 = time.time()
run("nohup kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data --timeout=240s >/root/drain1.log 2>&1 &")

prev_pods = {}
settled_since = None
uncordoned = False
drain_done_at = None
last_am = 0

while True:
    now = time.time()
    # drain 进程还在吗
    alive = run("pgrep -f 'kubectl dr[a]in' >/dev/null && echo yes || echo no")
    node_line = run("kubectl get node k8s-w1 --no-headers 2>/dev/null | awk '{print $2, $4}'")  # STATUS SCHEDULING
    podlines = run("kubectl get pods -n boutique -o wide --no-headers 2>/dev/null").splitlines()
    cur = {}
    w1_cnt = 0; term_cnt = 0
    for ln in podlines:
        parts = ln.split()
        if len(parts) < 8: continue
        name, status, node = parts[0], parts[2], parts[6]
        cur[name] = (status, node)
        if node == 'k8s-w1': w1_cnt += 1
        if status == 'Terminating': term_cnt += 1
        # 状态迁移事件
        if name in prev_pods and prev_pods[name] != (status, node):
            po, no = prev_pods[name]
            if status != po:
                emit(f'{rel()} | {name}: {po} -> {status}')
            if node != no:
                emit(f'{rel()} | {name}: 节点 {no} -> {node}')
    for name in prev_pods:
        if name not in cur:
            emit(f'{rel()} | {name}: 消失（被驱逐后待重建）')
    prev_pods = cur

    # 告警计数采样（每 10s）
    if now - last_am >= 10:
        last_am = now
        amcmd = ("curl -s -m 5 " + AM + ":9093/metrics | "
                 "grep -E '^alertmanager_notifications_total' | "
                 "grep -E 'email|webhook' | head -6")
        amc = run(amcmd)
        if amc:
            emit(rel() + ' | AM计数: ' + amc.replace('\n', ' | '))

    emit(f'{rel()} | 节点[{node_line}] w1残留pod={w1_cnt} terminating={term_cnt} 总pod={len(cur)}')

    # drain 结束
    if alive == 'no' and drain_done_at is None and now - t0 > 10:
        drain_done_at = now
        dlog = run('tail -5 /root/drain1.log')
        emit(f'=== drain 结束 T+{int(now-t0)}s，drain.log 尾部 ===')
        emit(dlog)
        run('kubectl uncordon k8s-w1')
        emit(f'{rel()} | uncordon 已执行')
        uncordoned = True
        time.sleep(10)

    # 收尾判定：uncordon 后所有 pod Running 且 w1 重新有 pod 驻留，稳定 20s
    all_running = all(v[0] == 'Running' for v in cur.values()) and len(cur) == 20
    w1_back = w1_cnt > 0
    if uncordoned and all_running and w1_back:
        if settled_since is None:
            settled_since = now
        elif now - settled_since >= 20:
            emit(f'=== 演练一结束 T+{int(now-t0)}s：全部 20 pod Running、w1 已重新承接 ===')
            break
    else:
        settled_since = None

    if now - t0 > 600:
        emit('!! 超时 600s，强制收尾')
        break
    time.sleep(2)

# ---- 4. 收尾：等探针自限结束后取数据 ----
emit('--- 等探针 600s 窗口自然结束 ---')
time.sleep(max(0, 600 - (time.time() - t0) - 30) if (time.time() - t0) < 570 else 5)
time.sleep(35)
out, err = run("kill -TERM $(pgrep -f 'availability-prob[e]' | head -1) 2>/dev/null; sleep 2; echo done"), None
probe_stat = run('tail -15 /root/probe-drill1.out')
emit('--- 探针统计摘要 ---')
emit(probe_stat)
sftp = c.open_sftp()
sftp.get('/root/probe-drill1.log', PLOG)
sftp.close()
emit(f'probe 原始数据已取回 {PLOG}')
c.close()
logf.close()
print('DRILL1 DONE')
