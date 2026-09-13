# 任务8收尾：currencyservice / paymentservice 内存 64Mi/128Mi -> 128Mi/256Mi
# 根因：payment(Node) 静息 92-102Mi 贴 128Mi limit 必 OOM；currency(Go) 流量毛刺打穿 128Mi
import io, re
import yaml

p = r'E:/yes/k8s-sre-platform/manifests/boutique/kubernetes-manifests.yaml'
s = io.open(p, encoding='utf-8').read()

targets = ['currencyservice', 'paymentservice']
for svc in targets:
    pat = re.compile(
        r'(name: ' + svc + r'\n.*?resources:\n\s+requests:\n\s+cpu: 100m\n\s+)memory: 64Mi(\n\s+limits:\n\s+cpu: 200m\n\s+)memory: 128Mi',
        re.S)
    s2, n = pat.subn(r'\g<1>memory: 128Mi\g<2>memory: 256Mi', s, count=1)
    assert n == 1, svc + ': replaced ' + str(n)
    s = s2

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

docs = [d for d in yaml.safe_load_all(io.open(p, encoding='utf-8')) if d]
for d in docs:
    if d.get('kind') == 'Deployment' and d['metadata']['name'] in targets:
        r = d['spec']['template']['spec']['containers'][0]['resources']
        print(d['metadata']['name'], '->', r['requests']['memory'], '/', r['limits']['memory'])
print('total docs:', len(docs), '| yaml OK')
