#!/usr/bin/env node
// Optional runtime browser evidence; never substitutes for the static G06 gate.
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';

const [docsArgument, outputArgument] = process.argv.slice(2);
if (!docsArgument || !outputArgument) throw new Error('usage: node scripts/qc/browser_docs.mjs DOCS_DIRECTORY NEW_OUTPUT_DIRECTORY');
const docs = await fs.realpath(docsArgument);
const output = path.resolve(outputArgument);
await fs.mkdir(output);
const report = { schema: 'weld.docs-browser-observation/2', status: 'running', checks: [], errors: [] };
const files = [];
async function walk(directory) {
  for (const name of await fs.readdir(directory)) {
    const file = path.join(directory, name);
    const stat = await fs.lstat(file);
    if (stat.isSymbolicLink()) throw new Error('browser payload contains a symlink');
    if (stat.isDirectory()) await walk(file);
    else if (name.endsWith('.html')) files.push(file);
  }
}
await walk(docs);
const mermaidPages = [];
for (const file of files.sort()) {
  const source = await fs.readFile(file, 'utf8');
  if (/<code\b[^>]*class=["'][^"']*\bmermaid\b[^"']*["']/i.test(source)) {
    mermaidPages.push({ file: path.relative(docs, file), sha256: crypto.createHash('sha256').update(source).digest('hex') });
  }
}
if (!mermaidPages.length) throw new Error('no Mermaid page found; browser rendering evidence requires a real diagram fixture');
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
const server = http.createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
    const file = await fs.realpath(path.join(docs, pathname === '/' ? 'index.html' : pathname));
    if (!file.startsWith(docs + path.sep)) throw new Error('path outside docs');
    response.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream' });
    response.end(await fs.readFile(file));
  } catch {
    response.writeHead(404); response.end('not found');
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}/`;
let browser;
try {
  const { chromium } = await import('playwright');
  browser = await chromium.launch({ headless: true });
  report.browser = browser.version();
  for (const theme of ['light', 'dark']) {
    const context = await browser.newContext({ colorScheme: theme });
    // ExDoc's rendering hook selects its Mermaid theme from this documented
    // body class. The UI theme-toggle still belongs to the manual checklist.
    await context.addInitScript(dark => {
      const setTheme = () => { if (document.body) document.body.classList.toggle('dark', dark); };
      new MutationObserver(setTheme).observe(document, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', setTheme);
    }, theme === 'dark');
    const page = await context.newPage();
    page.on('pageerror', error => report.errors.push(String(error)));
    await page.goto(base, { waitUntil: 'networkidle' });
    for (const item of mermaidPages) {
      const target = new URL(item.file, base).href;
      const candidates = page.locator('a[href]');
      let navigationLink;
      for (let index = 0; index < await candidates.count(); index++) {
        const candidate = candidates.nth(index);
        const href = await candidate.getAttribute('href');
        if (href && new URL(href, page.url()).href.split('#')[0] === target && await candidate.isVisible()) {
          navigationLink = candidate; break;
        }
      }
      let navigation = 'direct_load';
      if (navigationLink && page.url().split('#')[0] !== target) {
        await navigationLink.click();
        await page.waitForURL(url => url.href.split('#')[0] === target);
        navigation = 'actual_docs_link';
      } else {
        await page.goto(target, { waitUntil: 'networkidle' });
      }
      await page.waitForSelector('.mermaid svg', { state: 'visible', timeout: 30000 });
      const observed = await page.evaluate(() => ({
        svgCount: document.querySelectorAll('.mermaid svg').length,
        unrendered: document.querySelectorAll('pre code.mermaid').length,
        dark: document.body.classList.contains('dark'),
        syntaxErrors: document.querySelectorAll('.error-icon, .error-text').length
      }));
      if (!observed.svgCount || observed.unrendered || observed.syntaxErrors || observed.dark !== (theme === 'dark')) {
        throw new Error(`render failed: ${item.file} ${theme} ${JSON.stringify(observed)}`);
      }
      const screenshot = `${theme}-${crypto.createHash('sha256').update(item.file).digest('hex').slice(0, 12)}.png`;
      await page.screenshot({ path: path.join(output, screenshot), fullPage: true });
      report.checks.push({ ...item, theme, navigation, ...observed, screenshot });
    }
    await context.close();
  }
  if (!report.checks.some(check => check.navigation === 'actual_docs_link')) throw new Error('no in-site navigation was exercised; add a linked Mermaid extra');
  if (report.errors.length) throw new Error('browser reported JavaScript errors');
  report.status = 'passed';
  report.manualReview = ['Review screenshots', 'Toggle the real ExDoc theme control', 'Navigate back and forward between nested extras'];
} catch (error) {
  report.status = 'failed'; report.errors.push(String(error)); process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
  await fs.writeFile(path.join(output, 'browser.json'), JSON.stringify(report, null, 2), { flag: 'wx' });
}
