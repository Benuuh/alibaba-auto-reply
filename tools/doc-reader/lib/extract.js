// lib/extract.js - document extraction core: pdf(text/scan) / xlsx / csv / docx -> text + rendered images
// PDF engine: @hyzyla/pdfium (WASM, MIT wrapper) - no native canvas decoding, avoids pdfjs+napi-canvas native crashes.
'use strict';
const fs = require('fs');
const path = require('path');

const PDF_TEXT_MIN_CHARS = 100;
const DEFAULT_MAX_CHARS = 6000;
const DEFAULT_RENDER_PAGES = 2;
const RENDER_SCALE = 1.5;

let pdfiumLibPromise = null;
function getPdfiumLibrary() {
  if (!pdfiumLibPromise) {
    const { PDFiumLibrary } = require('@hyzyla/pdfium');
    pdfiumLibPromise = PDFiumLibrary.init();
  }
  return pdfiumLibPromise;
}

function truncate(text, maxChars) {
  if (typeof text !== 'string') return '';
  if (text.length <= maxChars) return text;
  return text.slice(0, maxChars);
}

function renderPageToPng(page) {
  const { createCanvas } = require('@napi-rs/canvas');
  return page.render({ scale: RENDER_SCALE }).then((r) => {
    const canvas = createCanvas(r.width, r.height);
    const ctx = canvas.getContext('2d');
    const imgData = ctx.createImageData(r.width, r.height);
    imgData.data.set(r.data);
    ctx.putImageData(imgData, 0, 0);
    return 'data:image/png;base64,' + canvas.toBuffer('image/png').toString('base64');
  });
}

async function extractPdf(filePath, maxChars, renderMaxPages) {
  const lib = await getPdfiumLibrary();
  const doc = await lib.loadDocument(fs.readFileSync(filePath));
  try {
    const pages = doc.getPageCount();
    let text = '';
    for (let i = 0; i < pages; i++) {
      try { text += (doc.getPage(i).getText() || '') + '\n'; } catch (e) { /* keep partial */ }
    }
    text = text.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
    if (text.length > PDF_TEXT_MIN_CHARS) {
      return { ok: true, kind: 'pdf-text', text: truncate(text, maxChars), images: [], meta: { pages, chars: text.length } };
    }
    // scan path: render first N pages to PNG data URLs (image-only scans have no usable text layer)
    const images = [];
    const n = Math.min(pages, Math.max(1, renderMaxPages));
    for (let i = 0; i < n; i++) {
      images.push(await renderPageToPng(doc.getPage(i)));
    }
    return { ok: true, kind: 'pdf-scan', text: truncate(text, maxChars), images, meta: { pages, rendered: images.length } };
  } finally {
    try { doc.destroy(); } catch (e) { /* ignore */ }
  }
}

function extractXlsx(filePath, maxChars) {
  const XLSX = require('xlsx');
  const wb = XLSX.readFile(filePath);
  const parts = [];
  const sheets = (wb.SheetNames || []).slice(0, 2);
  for (const name of sheets) {
    const ws = wb.Sheets[name];
    if (!ws) continue;
    parts.push('## ' + name);
    parts.push(XLSX.utils.sheet_to_csv(ws));
  }
  const text = parts.join('\n').trim();
  return { ok: true, kind: 'xlsx', text: truncate(text, maxChars), images: [], meta: { sheets: sheets.length, chars: text.length } };
}

function extractCsv(filePath, maxChars) {
  const text = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '').trim();
  return { ok: true, kind: 'csv', text: truncate(text, maxChars), images: [], meta: { chars: text.length } };
}

async function extractDocx(filePath, maxChars) {
  const mammoth = require('mammoth');
  const result = await mammoth.extractRawText({ path: filePath });
  const text = (result.value || '').trim();
  return { ok: true, kind: 'docx', text: truncate(text, maxChars), images: [], meta: { chars: text.length } };
}

async function extractFile(filePath, opts) {
  const maxChars = (opts && opts.maxChars) || DEFAULT_MAX_CHARS;
  const renderMaxPages = (opts && opts.renderMaxPages) || DEFAULT_RENDER_PAGES;
  if (!filePath || !fs.existsSync(filePath)) return { ok: false, error: 'not-found' };
  const ext = path.extname(filePath).toLowerCase();
  try {
    if (ext === '.pdf') return await extractPdf(filePath, maxChars, renderMaxPages);
    if (ext === '.xlsx' || ext === '.xls') return extractXlsx(filePath, maxChars);
    if (ext === '.csv') return extractCsv(filePath, maxChars);
    if (ext === '.docx') return await extractDocx(filePath, maxChars);
    return { ok: false, error: 'unsupported' };
  } catch (e) {
    return { ok: false, error: 'parse-failed', message: String(e && e.message ? e.message : e) };
  }
}

module.exports = { extractFile, truncate, PDF_TEXT_MIN_CHARS };
