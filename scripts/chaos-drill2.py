# 演练二：节点硬宕机观测器（w2 由用户在阿里云控制台强制关机，本脚本负责全部观测）
# 用法:
#   python chaos-drill2.py <password> watch   # 在用户点下"强制关机"的同时启动，观测 12 分钟
#   python chaos-drill2.py <password> resume  # 用户开机后执行：uncordon + 等 Ready + 恢复通知观测
# 产出: docs/chaos-drill2-timeline.log
import paramiko, time, sys, io, datetime

PASS = sys.argv[1]
PHASE = sys.argv[2] if len(sys.argv) > 2 else 'watch'
TLOG = r'E:/yes/k8s-sre-platform/docs/chaos-drill2-timeline.log'

logf = io.open(TLOG, 'a' if PHASE == 'resume' else 'w', encoding='utf-8', newline='\n')

def ts():
    return datetime.datetime.now().strftime('%H:%M:%S')

def emit(msg):
    line = f'[{ts()}] {msg}'
    print(line, flush=True)
    logf.write(line + '\n')
    logf.flush()

c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('8.155.129.89', username='root', password=PASS, timeout=15, look_for_keys=False, allow_agent=False)

def run(cmd, t=60):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode().strip() or e.read().decode().strip()

AM = run("kubectl -n monitoring get svc kube-prometheus-stack-alertmanager -o jsonpath='{.spec.clusterIP}'")

def am_counters():
    out = run("curl -s -m 5 " + AM + ":9093/metrics | "
              "grep -E '^alertmanager_notifications_total' | grep -E 'email|webhook' | head -6")
    return out.replace('\n', ' | ') if out else '(采样失败)'

if PHASE == 'watch':
    # 上传并启动探针（900s 自限，覆盖 NotReady 40s + 驱逐 300s + 重建 + 余量）
    sftp = c.open_sftp()
    sftp.put(r'E:/yes/k8s-sre-platform/scripts/availability-probe.sh', '/root/availability-probe.sh')
    sftp.close()
    run("nohup bash /root/availability-probe.sh http://127.0.0.1:30080/ -d 900 -o /root/probe-drill2.log >/root/probe-drill2.out 2>&1 &")
    emit('=== 演练二观测开始（假定 T0=现在，用户应已按下强制关机）===')
    emit('探针已启动（900s 自限）')
    emit('AM 计数基线: ' + am_counters())
    emit(run("kubectl get pods -n boutique -o wide --no-headers | awk '{print $1, $3, $7}' | grep w2 || true"))

    prev = {}
    t0 = time.time()
    last_am = 0
    recovery_since = None
    while time.time() - t0 < 720:
        node_line = run("kubectl get node k8s-w2 --no-headers 2>/dev/null | awk '{print $2}'")
        podlines = run("kubectl get pods -n boutique -o wide --no-headers 2>/dev/null").splitlines()
        cur = {}
        w2 = 0
        for ln in podlines:
            p = ln.split()
            if len(p) < 8: continue
            cur[p[0]] = (p[2], p[6])
            if p[6] == 'k8s-w2': w2 += 1
        for name in prev:
            if name not in cur:
                emit(f'T+{int(time.time()-t0)}s | {name}: 消失')
        for name in cur:
            st, nd = cur[name]
            if name in prev and prev[name] != (st, nd):
                po, no = prev[name]
                if st != po:
                    emit(f'T+{int(time.time()-t0)}s | {name}: {po} -> {st}')
                if nd != no:
                    emit(f'T+{int(time.time()-t0)}s | {name}: 节点 {no} -> {nd}')
        prev = cur
        if time.time() - last_am >= 10:
            last_am = time.time()
            emit(f'T+{int(time.time()-t0)}s | 节点w2[{node_line}] w2上pod={w2} | AM: {am_counters()}')
        # 服务恢复判定：全部 Running 且稳定 30s
        if all(v[0] == 'Running' for v in cur.values()) and len(cur) == 20 and node_line in ('Ready', 'NotReady', 'SchedulingDisabled'):
            if recovery_since is None:
                recovery_since = time.time()
            elif time.time() - recovery_since >= 30 and time.time() - t0 > 400:
                emit(f'=== 服务已恢复稳定 T+{int(time.time()-t0)}s（pod 全 Running 30s+）===')
                emit('>>> 现在去阿里云控制台开机 k8s-w2，开好后告诉我 <<<')
                break
        else:
            recovery_since = None
        time.sleep(2)
    emit(f'--- watch 阶段结束 T+{int(time.time()-t0)}s ---')

else:  # resume
    emit('=== resume：用户已开机 ===')
    emit('uncordon 前 AM 计数: ' + am_counters())
    run('kubectl uncordon k8s-w2')
    emit('uncordon 已执行')
    for i in range(60):
        st = run("kubectl get node k8s-w2 --no-headers | awk '{print $2}'")
        if st == 'Ready':
            emit(f'节点 Ready（{i*5}s 内）')
            break
        time.sleep(5)
    # 观察 60s：看是否有 pod 迁回、恢复通知计数
    time.sleep(60)
    emit('节点恢复后 AM 计数: ' + am_counters())
    emit(run("kubectl get pods -n boutique -o wide --no-headers | awk '{print $1, $3, $7}' | grep w2 || echo '(无 pod 迁回 w2 —— 预期行为，无自动 rebalance)'"))
    out = run('tail -15 /root/probe-drill2.out')
    emit('--- 探针统计摘要 ---')
    emit(out)
    sftp = c.open_sftp()
    sftp.get('/root/probe-drill2.log', r'E:/yes/k8s-sre-platform/docs/probe-drill2.log')
    sftp.close()
    emit('probe-drill2.log 已取回')

c.close()
logf.close()
print('DRILL2', PHASE.upper(), 'DONE')
