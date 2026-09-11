// tests/read.test.js - doc-reader component tests (node --test)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { extractFile } = require('../lib/extract');
const { makeTextPdf, makeShortPdf, makeXlsx, makeCsv, makeDocx } = require('./helpers/make_fixtures');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'docreader-tests-'));
const fText = path.join(tmp, 'fixture_text.pdf');
const fScan = path.join(tmp, 'fixture_scan.pdf');
const fXlsx = path.join(tmp, 'fixture.xlsx');
const fCsv = path.join(tmp, 'fixture.csv');
const fDocx = path.join(tmp, 'fixture.docx');
const fTxt = path.join(tmp, 'fixture.txt');

test.before(() => {
  makeTextPdf(fText);
  makeShortPdf(fScan);
  makeXlsx(fXlsx);
  makeCsv(fCsv);
  makeDocx(fDocx);
  fs.writeFileSync(fTxt, 'plain', 'utf8');
});

test.after(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

test('pdf-text: >100 chars text layer extracted, no images', async () => {
  const r = await extractFile(fText);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.kind, 'pdf-text');
  assert.ok(r.text.length > 100);
  assert.match(r.text, /47kg/);
  assert.strictEqual(r.images.length, 0);
});

test('pdf-scan: short text layer falls back to rendered PNG pages', async () => {
  const r = await extractFile(fScan, { renderMaxPages: 2 });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.kind, 'pdf-scan');
  assert.ok(r.images.length >= 1);
  assert.ok(r.images[0].startsWith('data:image/png;base64,'));
  const raw = Buffer.from(r.images[0].split(',')[1], 'base64');
  assert.deepStrictEqual(Array.from(raw.slice(0, 8)), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
});

test('xlsx: first sheets converted to text', async () => {
  const r = await extractFile(fXlsx);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.kind, 'xlsx');
  assert.match(r.text, /Carton A/);
  assert.match(r.text, /47kg/);
});

test('csv: raw text', async () => {
  const r = await extractFile(fCsv);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.kind, 'csv');
  assert.match(r.text, /Carton A/);
});

test('docx: raw text extracted', async () => {
  const r = await extractFile(fDocx);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.kind, 'docx');
  assert.match(r.text, /47kg/);
  assert.match(r.text, /TRK123456/);
});

test('truncation: maxChars caps text length', async () => {
  const r = await extractFile(fText, { maxChars: 30 });
  assert.strictEqual(r.ok, true);
  assert.ok(r.text.length <= 30);
});

test('unsupported extension and missing file', async () => {
  const a = await extractFile(fTxt);
  assert.strictEqual(a.ok, false);
  assert.strictEqual(a.error, 'unsupported');
  const b = await extractFile(path.join(tmp, 'nope.pdf'));
  assert.strictEqual(b.ok, false);
  assert.strictEqual(b.error, 'not-found');
});
