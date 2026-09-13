#!/usr/bin/env python3
# =============================================================================
# 任务 8 HPA 压测自动化（在用户本机运行，通过 SSH 代操作 k8s-cp）
#
# 干什么：
#   1. 记录压测前基线（hpa / top / OOM 排雷）
#   2. 在 cp 上后台启动 hey -z 5m -c 50 http://127.0.0.1:30080/
#   3. 每 3s 轮询 HPA 副本数与利用率，每 15s 采 frontend CPU + 商店延迟
#      → 全部带时间戳写入 docs/hpa-drill-timeline.log（截图 17 的数据源）
#   4. 压测结束取回 hey 输出 → docs/hpa-hey-result.txt（截图 18 的数据源）
#   5. 缩容阶段每 20s 轮询，回到 2 副本后连续 3 次确认才收尾
#
# 用法：python hpa-drill.py <ECS root 密码>
# =============================================================================
import sys, time, datetime, paramiko

HOST = '8.155.129.89'
USER = 'root'
LOG_PATH = r'E:/yes/k8s-sre-platform/docs/hpa-drill-timeline.log'
HEY_LOCAL = r'E:/yes/k8s-sre-platform/docs/hpa-hey-result.txt'
HEY_REMOTE = '/root/hey-run.log'
HEY_BIN = '/root/go/bin/hey'
URL = 'http://127.0.0.1:30080/'

f = open(LOG_PATH, 'a', encoding='utf-8')

def now():
    return datetime.datetime.now().strftime('%H:%M:%S')

def emit(line):
    f.write(f'[{now()}] {line}\n'); f.flush()
    print(f'[{now()}] {line}', flush=True)

def connect(pw):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=pw, timeout=15,
              look_for_keys=False, allow_agent=False)
    return c

def run(c, cmd, timeout=30):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    out = o.read().decode('utf-8', 'replace').strip()
    err = e.read().decode('utf-8', 'replace').strip()
    return out, err

def parse_hpa(c):
    # 用 jsonpath 取结构化字段。不能用 --no-headers 按列 split：
    # TARGETS 列的值 "cpu: 11%/60%" 本身带空格，会把 MAXPODS 误当副本数（run1 踩过）
    out, _ = run(c, "kubectl get hpa frontend-hpa -n boutique -o "
                    "jsonpath='{.status.currentReplicas}|"
                    "{.status.currentMetrics[0].resource.current.averageUtilization}' 2>&1")
    parts = out.split('|')
    if len(parts) != 2 or not parts[0].isdigit():
        return None, None, f'解析失败: {out}'
    replicas, cpu = parts[0], parts[1]
    return f'cpu:{cpu}%', replicas, f'replicas={replicas} cpu={cpu}%'

def main():
    pw = sys.argv[1]
    c = connect(pw)
    emit(f'=== 任务8 HPA 压测开始，已连接 {HOST} ===')

    # ---- 0. 基线 ----
    emit('--- 压测前基线 ---')
    for label, cmd in [
        ('OOM排雷', "kubectl get pods -n boutique -o custom-columns="
                    "'NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,"
                    "LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason' "
                    "| awk '$2>0 || NR==1'"),
        ('HPA基线', "kubectl get hpa -n boutique --no-headers"),
        ('frontendPod', "kubectl top pods -n boutique 2>/dev/null | grep frontend"),
        ('商店延迟', f"curl -s -o /dev/null -w '%{{http_code}} %{{time_total}}s' {URL}"),
    ]:
        out, err = run(c, cmd)
        emit(f'{label}: {out or err}')

    # ---- 0.5 等待回到基线副本数（缩容稳定窗口 300s，重跑前先等回落）----
    emit('--- 等待 HPA 回到 2 副本基线（最长 10 分钟）---')
    deadline = time.time() + 600
    while time.time() < deadline:
        _, replicas, raw = parse_hpa(c)
        if replicas == '2':
            emit(f'基线确认：{raw}')
            break
        emit(f'当前 {raw}，继续等待…')
        time.sleep(20)

    # ---- 1. 启动 hey（cp 后台，nohup 防 SSH 断连）----
    out, err = run(c, "pgrep -x hey >/dev/null && pkill -x hey && echo '已清掉残留 hey' || echo '无残留 hey'")
    emit(f'hey 前置清理: {out or err}')
    emit(f'--- 启动压测 hey -z 5m -c 50 {URL} ---')
    out, err = run(c,
        f"nohup bash -c 'date +%T; {HEY_BIN} -z 5m -c 50 {URL}; date +%T' "
        f"> {HEY_REMOTE} 2>&1 & echo LAUNCHED")
    emit(f'hey 启动: {out or err}')

    # ---- 2. 压测期轮询（6.5 分钟）----
    load_end = time.time() + 390
    poll, slow = 0, 0
    prev_replicas = None
    events = []
    while time.time() < load_end:
        poll += 1
        try:
            targets, replicas, raw = parse_hpa(c)
            if targets is None:
                emit(f'HPA解析失败: {raw}')
            else:
                if replicas != prev_replicas:
                    emit(f'★ 副本数变化 {prev_replicas} -> {replicas}（TARGETS {targets}）')
                    events.append((now(), replicas, targets))
                    prev_replicas = replicas
                else:
                    emit(f'副本 {replicas}  TARGETS {targets}')
        except Exception as ex:
            emit(f'轮询异常（将重连）: {ex}')
            try: c.close()
            except Exception: pass
            time.sleep(3)
            c = connect(pw)
        if poll % 5 == 0:  # 每 15s 的慢采样
            slow += 1
            tops = run(c, "kubectl top pods -n boutique 2>/dev/null | grep frontend "
                          "| awk '{print $1, $2}'")[0].replace('\n', '; ')
            lat = run(c, f"curl -s -o /dev/null -w '%{{http_code}} %{{time_total}}' {URL}")[0]
            emit(f'慢采样# slow={slow} frontendPods[{tops}] 商店探测[{lat}]')
        time.sleep(3)

    emit('--- 压测时间窗结束，取 hey 报告 ---')
    hey_out, _ = run(c, f'cat {HEY_REMOTE}', timeout=20)
    with open(HEY_LOCAL, 'w', encoding='utf-8') as hf:
        hf.write(hey_out + '\n')
    emit(f'hey 输出已存 {HEY_LOCAL}（{len(hey_out)} 字符）')

    # ---- 3. 缩容观察（最长 25 分钟，连续 3 次为 2 才收）----
    emit('--- 缩容观察期 ---')
    stable, prev_replicas = 0, None
    deadline = time.time() + 1500
    while time.time() < deadline and stable < 3:
        targets, replicas, raw = parse_hpa(c)
        if replicas is not None:
            if replicas != prev_replicas:
                emit(f'★ 副本数变化 {prev_replicas} -> {replicas}（TARGETS {targets}）')
                events.append((now(), replicas, targets))
                prev_replicas = replicas
                stable = 0
            elif replicas == '2':
                stable += 1
                emit(f'副本 {replicas}（稳定计数 {stable}/3）')
            else:
                emit(f'副本 {replicas}  TARGETS {targets}')
        time.sleep(20)

    # ---- 4. 收尾 ----
    emit('--- 收尾状态 ---')
    for label, cmd in [
        ('HPA终态', "kubectl get hpa -n boutique --no-headers"),
        ('frontendPod', "kubectl top pods -n boutique 2>/dev/null | grep frontend"),
        ('节点水位', "kubectl top nodes"),
    ]:
        out, err = run(c, cmd)
        emit(f'{label}: {out or err}')
    emit('=== 压测流程结束 ===')
    print('\nSUMMARY_EVENTS:')
    for t, r, tg in events:
        print(f'  {t}  replicas={r}  targets={tg}')
    c.close()

if __name__ == '__main__':
    main()
