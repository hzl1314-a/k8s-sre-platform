# HANDOFF 遗留清单更新：OOMKilled 关闭 + kube-proxy 补闭环标记
import io

p = r'E:/yes/k8s-sre-platform/docs/HANDOFF.md'
s = io.open(p, encoding='utf-8').read()

old1 = """- [ ] **有 Pod 累计重启 2-3 次**，待查是否 OOMKilled：
      `kubectl get pods -n boutique -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason'`
      （若是 OOM 就调 limit，并写进踩坑记录——监控第一次跑就抓到真问题，是加分项）"""
new1 = """- [x] **有 Pod 累计重启 2-3 次（OOMKilled，已修复 2026-09-14 凌晨）**：
      实锤 currencyservice / paymentservice 各 4-5 次；payment(Node) 静息 92-102Mi
      贴 128Mi limit（懒 GC 顶到 cgroup 才回收，OOM 必然），currency(Go) 流量毛刺
      打穿 128Mi → 两者提到 request 128Mi / limit 256Mi（`scripts/patch-mem-limits.py`
      原子改清单），滚动更新后零重启、商店 200。排查中连带修掉一次「apply 忘带 -n
      误建全套到 default ns」事故（delete -f 精确清理 + SFTP 重传 md5 校验），
      全程见 `docs/autoscaling.md` §6 踩坑表——「监控第一次跑就抓到真问题」达成"""
assert s.count(old1) == 1
s = s.replace(old1, new1)

old2 = """- [~] **kube-proxy 抓取目标全挂（已拍板 2026-09-13 晚：关抓取，待上云）**：
      values 已改 `kubeProxy.enabled: false`，本地渲染验证 diff 干净（只消失
      ServiceMonitor / Service / PrometheusRule / Grafana 看板 4 个资源）；
      待执行 `helm upgrade`，命令与验证见 `docs/autoscaling.md` 第 0 步"""
new2 = """- [x] **kube-proxy 抓取目标全挂（已闭环 2026-09-14 00:05）**：
      `kubeProxy.enabled: false` 已上云，三步验证全过：ServiceMonitor 已删、
      targets 无 kube-proxy、`up == 0` 空且 ScrapeTargetDown 清零。
      本地渲染 diff 验证先例（只消失 4 个资源）保留在
      `downloads/render-kps-{before,after}.out`"""
assert s.count(old2) == 1
s = s.replace(old2, new2)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('HANDOFF leftovers: 2 items closed OK')
