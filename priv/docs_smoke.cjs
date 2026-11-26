// Usage: node docs_smoke.cjs <docs_dir>  (resolves "playwright" via NODE_PATH)
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const dir = path.resolve(process.argv[2]);
const pages = fs.readdirSync(dir).filter((f) => f.endsWith(".html"));
const blocks = (f) => (fs.readFileSync(path.join(dir, f), "utf8").match(/<code class="mermaid"/g) || []).length;
const mermaidPages = pages.filter((f) => blocks(f) > 0);
const errors = [];

(async () => {
  const browser = await chromium.launch();
  for (const scheme of ["light", "dark"]) {
    for (const page of mermaidPages) {
      const ctx = await browser.newContext({ colorScheme: scheme });
      const p = await ctx.newPage();
      p.on("pageerror", (e) => errors.push(`${page} [${scheme}] pageerror: ${e.message}`));
      p.on("console", (m) => {
        if (m.type() === "error" && !m.text().includes("Failed to load resource"))
          errors.push(`${page} [${scheme}] console: ${m.text()}`);
      });
      await p.goto("file://" + path.join(dir, page));
      await p.waitForFunction((n) => document.querySelectorAll(".mermaid svg").length >= n, blocks(page), { timeout: 15000 })
        .catch(() => errors.push(`${page} [${scheme}] direct load: mermaid SVG not rendered`));
      await ctx.close();
    }
  }
  // In-site navigation: open index, then follow a link to each mermaid page.
  for (const page of mermaidPages) {
    const ctx = await browser.newContext();
    const p = await ctx.newPage();
    p.on("pageerror", (e) => errors.push(`${page} [nav] pageerror: ${e.message}`));
    await p.goto("file://" + path.join(dir, "index.html"));
    // index.html redirects to the main page; wait for that to settle.
    await p.waitForURL((u) => !u.toString().endsWith("index.html"), { timeout: 5000 }).catch(() => {});
    await p.waitForLoadState("load");
    const link = await p.$(`a[href="${page}"]`);
    const linked = !!link;
    // The click may start a navigation that destroys this evaluate's context.
    if (link) await link.evaluate((el) => el.click()).catch(() => {});
    if (!linked) {
      errors.push(`${page} [nav] no sidebar link from index.html`);
    } else {
      await p.waitForFunction((n) => document.querySelectorAll(".mermaid svg").length >= n, blocks(page), { timeout: 15000 })
        .catch(() => errors.push(`${page} [nav] in-site navigation: mermaid SVG not rendered`));
    }
    await ctx.close();
  }
  await browser.close();
  console.log(JSON.stringify({ pages: mermaidPages, errors }));
  process.exit(errors.length ? 1 : 0);
})();
