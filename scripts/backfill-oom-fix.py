# 任务8收尾回填：OOMKilled 排查结论 + 误建命名空间事故记录
import io

p = r'E:/yes/k8s-sre-platform/docs/autoscaling.md'
s = io.open(p, encoding='utf-8').read()

anchor = '| Grafana 页面截图 basic auth 无效'
assert s.count(anchor) == 1
addition = anchor + """
| ★ 遗留 OOMKilled 排查（任务 8 收尾） | currencyservice/paymentservice 各 4-5 次重启，LASTSTATE=OOMKilled → 实测：payment(Node) 静息 92-102Mi 贴 128Mi limit（78%，Node 懒 GC 顶到 cgroup 才回收，OOM 是必然）；currency(Go) 静息仅 30Mi 但请求毛刺打穿 128Mi → 两者内存提到 request 128Mi / limit 256Mi（约 2 倍静息水位），滚动更新后新 pods 零重启、商店 200。**教训：巡检告警里 RESTARTS 持续增长的 Pod 要查 limit vs 实际用量，payment 这种「静息就贴线」不是调 JVM/堆参数能救的，limit 本身定小了** |
| ★ kubectl apply 忘带 -n（我踩的） | 全套 boutique 被建进 default 命名空间——诊断线索是输出全是 `created`（正常滚动应为 `configured/unchanged`）+ Deployment AGE 没变 + scp 实际失败（远端还是旧文件，md5 对不上）→ 用 `delete -f 同一份文件` 精确清理误建资源，SFTP 重传（md5 校验一致）后带 `-n boutique` 重 apply。**教训：① apply 后 `created/configured/unchanged` 三态要先看再动；② 传完文件先对 md5 再执行变更；③ delete -f 与 apply -f 用同一份文件是精确回滚误操作的可靠手段** |"""
s = s.replace(anchor, addition)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('autoscaling.md pitfalls +2 OK')

# ---- HANDOFF 遗留清单 ----
p2 = r'E:/yes/k8s-sre-platform/docs/HANDOFF.md'
s2 = io.open(p2, encoding='utf-8').read()
old = '- [ ] **boutique 部分服务频繁重启待查（OOMKilled 嫌疑）**'
if old not in s2:
    # 找不到原文就宽松一点，避免误判
    import re
    m = re.search(r'- \[[ ~x]\] \*\*boutique 部分服务频繁重启[^\n]*\n(?:\s+[^\n]*\n)*?', s2)
    assert m, '遗留条目未找到'
    old = m.group(0).rstrip('\n')
new = """- [x] **boutique 部分服务频繁重启（OOMKilled，已修复 2026-09-14 凌晨）**：
      payment(Node) 静息 92-102Mi 贴 128Mi limit、currency(Go) 流量毛刺打穿 128Mi
      → 两者提到 128Mi/256Mi（`scripts/patch-mem-limits.py` 原子改清单），
      滚动更新后零重启、商店 200。排查过程中还连带发现并修掉一次
      「apply 忘带 -n 误建全套到 default ns」的事故（delete -f 精确清理），
      全程记录见 `docs/autoscaling.md` §6 踩坑表"""
s2 = s2.replace(old, new)
io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('HANDOFF leftover item closed OK')
