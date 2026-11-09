const { chromium } = require('../.tools/browser/node_modules/playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
    const baseUrl = process.argv[2] || process.env.MAESTER_PREVIEW_URL || 'http://localhost:7072';
    const browser = await chromium.launch({ channel: 'msedge', headless: true });
    const output = path.join(__dirname, '../TestResults');
    fs.mkdirSync(output, { recursive: true });
    try {
        for (const viewport of [{ width: 1440, height: 1100 }, { width: 390, height: 844 }, { width: 320, height: 740 }]) {
            const page = await browser.newPage({ viewport });
            const errors = [];
            page.on('pageerror', error => errors.push(error.message));
            await page.goto(baseUrl);
            await page.waitForFunction(() => document.getElementById('status').textContent === 'Live');
            assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, 'Horizontal overflow');
            assert.equal(await page.locator('.brand svg').count(), 1, 'Icon asset missing');
            assert.equal(await page.evaluate(() => {
                const canvas = document.getElementById('memory-chart');
                const chart = Chart.getChart(canvas);
                const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
                return chart.data.datasets[0].data.length > 0 && data.some((value, index) => index % 4 === 3 && value > 0);
            }), true, 'Memory chart is blank');
            await page.locator('#pause').click();
            assert.equal(await page.locator('#pause').getAttribute('aria-pressed'), 'true');
            await page.locator('#pause').click();
            await page.locator('[data-view="runtime"]').click();
            assert.equal(await page.locator('[data-section="execution"]').isVisible(), false);
            await page.locator('[data-view="overview"]').click();
            await page.screenshot({ path: path.join(output, `dashboard-${viewport.width}.png`), fullPage: true });
            assert.deepEqual(errors, [], 'Browser errors');
            console.log(`Dashboard ${viewport.width}x${viewport.height}: passed`);
            await page.close();
        }
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });