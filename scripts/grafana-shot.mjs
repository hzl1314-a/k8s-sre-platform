// Grafana 自动登录 + 截图（驱动本机 Chrome，无需下载浏览器内核）
// 用法: node grafana-shot.mjs <password> <outdir> [timeRange] [outName]
//   timeRange: Grafana from/to 参数，如 now-30m；默认 now-30m
//   outName:   输出文件名，默认 grafana-shot.png
import { createRequire } from 'module';
import { readFileSync } from 'fs';
const require = createRequire('C:/Users/Lenovo/.workbuddy/binaries/node/workspace/node_modules/');
const puppeteer = require('puppeteer-core');

const [,, passFile, outDir, range = 'now-30m', outName = 'grafana-shot.png'] = process.argv;
if (!passFile || !outDir) { console.error('usage: node grafana-shot.mjs <credFile> <outDir> [range] [name]'); process.exit(1); }
const password = readFileSync(passFile, 'utf8').trim();
const base = 'http://8.155.129.89:30300';

const browser = await puppeteer.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: 'new',
  args: ['--no-proxy-server', '--window-size=1680,1050'],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1680, height: 1050 });

  // 登录
  await page.goto(`${base}/login`, { waitUntil: 'networkidle2', timeout: 30000 });
  await page.waitForSelector('input[name="user"]', { timeout: 15000 });
  await page.type('input[name="user"]', 'admin', { delay: 20 });
  await page.type('input[name="password"]', password, { delay: 20 });
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 30000 }).catch(() => {}),
    page.click('button[type="submit"]'),
  ]);

  // 跳过改密码页（如出现）；登录后停 2s 让会话 cookie 稳定（诊断脚本实测有效）
  await new Promise(r => setTimeout(r, 2000));
  if (page.url().includes('password')) {
    await page.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: 30000 }).catch(() => {});
  }

  // 打开看板（kiosk 模式 + 指定时间范围）——参数形态与实测成功的诊断脚本保持一致
  const url = `${base}/d/boutique-overview/?from=${range}&to=now&kiosk`;
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 45000 });
  // 实测固定 15s 等待即可完整渲染（首查+绘制）
  await new Promise(r => setTimeout(r, 15000));
  await page.screenshot({ path: `${outDir}/${outName}` });
  console.log('OK:', `${outDir}/${outName}`);
} finally {
  await browser.close();
}
