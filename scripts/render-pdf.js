#!/usr/bin/env node
/**
 * Render HTML to PDF using Puppeteer with native headers/footers.
 *
 * Usage: node render-pdf.js <input.html> <output.pdf> [options-json]
 *
 * Options JSON:
 *   pageOffset: number (default 0) — added to page numbers
 *   headerHtml: string — header template
 *   footerHtml: string — footer template
 *   noHeaderFooter: boolean — suppress headers/footers (for cover/back cover)
 */

const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');

const CHROMIUM_PATH = process.env.CHROMIUM_PATH || '/usr/bin/chromium';

async function renderPdf(inputHtml, outputPdf, options = {}) {
  const browser = await puppeteer.launch({
    executablePath: CHROMIUM_PATH,
    headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage']
  });

  try {
    const page = await browser.newPage();
    // Tall viewport ensures all pages are "visible" so Chromium generates
    // link annotations for all anchor tags, not just those in initial view
    await page.setViewport({ width: 816, height: 100000 });
    const html = fs.readFileSync(inputHtml, 'utf-8');
    await page.setContent(html, { waitUntil: 'networkidle0' });

    const pdfOptions = {
      path: outputPdf,
      format: 'Letter',
      printBackground: true,
      margin: { top: '0mm', bottom: '0mm', left: '0mm', right: '0mm' }
    };

    if (options.bodyMode) {
      // Full bleed — zero margins, page divs handle their own padding
      // Links preserved via tall viewport (100,000px) not margins
      pdfOptions.displayHeaderFooter = false;
    } else if (options.noHeaderFooter) {
      // Cover and back cover — no margins, no headers/footers
      pdfOptions.displayHeaderFooter = false;
    } else {
      // Body pages with Puppeteer native headers and footers
      pdfOptions.margin = { top: '22mm', bottom: '20mm', left: '14mm', right: '14mm' };
      pdfOptions.displayHeaderFooter = true;
      pdfOptions.headerTemplate = options.headerHtml || '<span></span>';
      pdfOptions.footerTemplate = options.footerHtml || '<span></span>';
    }

    await page.pdf(pdfOptions);
  } finally {
    await browser.close();
  }
}

// Parse args
const [,, inputHtml, outputPdf, optionsJson] = process.argv;
if (!inputHtml || !outputPdf) {
  console.error('Usage: render-pdf.js <input.html> <output.pdf> [options-json]');
  process.exit(1);
}

const options = optionsJson ? JSON.parse(optionsJson) : {};
renderPdf(inputHtml, outputPdf, options)
  .then(() => console.log(`PDF written: ${outputPdf}`))
  .catch(err => { console.error(`PDF failed: ${err.message}`); process.exit(1); });
