#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const pagesRoot = join(repositoryRoot, "pages");
const assetsRoot = join(repositoryRoot, "site-assets");
const errors = [];
const warnings = [];
const counts = {
  html: 0,
  stylesheets: 0,
  scripts: 0,
  assets: 0,
  localReferences: 0,
  externalLinks: 0,
  anchors: 0,
};

const reportError = (message) => errors.push(message);
const reportWarning = (message) => warnings.push(message);

function walk(directory, predicate) {
  if (!existsSync(directory)) return [];
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const entryPath = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...walk(entryPath, predicate));
    else if (predicate(entryPath)) files.push(entryPath);
  }
  return files;
}

function displayPath(filePath) {
  const result = relative(repositoryRoot, filePath);
  return result || filePath;
}

function isExternalUrl(value) {
  return /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(value);
}

function isIgnoredUrl(value) {
  return /^(?:data:|mailto:|tel:|javascript:|#)/i.test(value) || value.trim() === "";
}

function decodePath(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function localPathFor(value, sourceFile) {
  const withoutFragment = value.split("#", 1)[0].split("?", 1)[0];
  if (withoutFragment === "") return null;
  const decoded = decodePath(withoutFragment);
  if (decoded.startsWith("/")) return resolve(repositoryRoot, decoded.slice(1));
  return resolve(dirname(sourceFile), decoded);
}

function checkUrl(value, sourceFile, kind, allowEmpty = false) {
  const trimmed = value.trim();
  if (!trimmed) {
    if (!allowEmpty) reportError(`${displayPath(sourceFile)}: empty ${kind} URL`);
    return;
  }

  if (isIgnoredUrl(trimmed)) {
    if (/^javascript:/i.test(trimmed)) reportError(`${displayPath(sourceFile)}: javascript: URL is not allowed`);
    return;
  }

  if (isExternalUrl(trimmed)) {
    counts.externalLinks += 1;
    try {
      const url = new URL(trimmed);
      if (!["https:", "http:", "mailto:", "tel:"].includes(url.protocol)) {
        reportError(`${displayPath(sourceFile)}: unsupported ${kind} protocol in ${trimmed}`);
      }
    } catch {
      reportError(`${displayPath(sourceFile)}: malformed ${kind} URL ${trimmed}`);
    }
    return;
  }

  counts.localReferences += 1;
  const target = localPathFor(trimmed, sourceFile);
  if (!target || !existsSync(target) || !statSync(target).isFile()) {
    reportError(`${displayPath(sourceFile)}: missing local ${kind} target ${trimmed} -> ${target ? displayPath(target) : "(none)"}`);
  }
}

function collectIds(html, sourceFile) {
  const ids = new Set();
  const duplicates = [];
  for (const match of html.matchAll(/\bid\s*=\s*(["'])(.*?)\1/gi)) {
    const id = match[2];
    if (ids.has(id)) duplicates.push(id);
    ids.add(id);
  }
  for (const id of duplicates) reportError(`${displayPath(sourceFile)}: duplicate id #${id}`);
  return ids;
}

function checkAnchors(html, ids, sourceFile) {
  for (const match of html.matchAll(/\bhref\s*=\s*(["'])#([^"']+)\1/gi)) {
    counts.anchors += 1;
    if (!ids.has(match[2])) reportError(`${displayPath(sourceFile)}: anchor #${match[2]} does not exist in this page`);
  }
}

function checkHtmlFile(filePath) {
  const html = readFileSync(filePath, "utf8");
  const source = displayPath(filePath);
  const ids = collectIds(html, filePath);
  checkAnchors(html, ids, filePath);

  if (!/<!doctype\s+html>/i.test(html)) reportError(`${source}: missing HTML5 doctype`);
  if (!/<html\b[^>]*\blang\s*=\s*(["'])ja\1/i.test(html)) reportError(`${source}: html element must declare lang="ja"`);
  if (!/<title\b[^>]*>[^<]+<\/title>/i.test(html)) reportError(`${source}: missing non-empty title`);
  if (!/<main\b/i.test(html)) reportError(`${source}: missing main landmark`);
  if (!/<h1\b/i.test(html)) reportError(`${source}: missing h1`);
  if (!/class\s*=\s*(["'])skip-link\1/i.test(html)) reportError(`${source}: missing skip link`);

  const requiredPhrases = [
    "local-first Japanese Language Runtime",
    "Mozc",
    "Phase 1",
    "Workbench/CLI",
    "NOT A TSF / IME",
    "Google 日本語入力",
    "PROPRIETARY CODE + DATA / DO NOT REUSE",
    "プライバシー",
    "ロードマップ",
    "engineering preview",
    "ダウンロード",
    "FAQ",
  ];
  for (const phrase of requiredPhrases) {
    if (!html.includes(phrase)) reportError(`${source}: required product content missing: ${phrase}`);
  }

  for (const match of html.matchAll(/<img\b[^>]*>/gi)) {
    const tag = match[0];
    if (!/\balt\s*=\s*(["']).*?\1/i.test(tag)) reportError(`${source}: img needs an alt attribute (${tag.slice(0, 100)})`);
  }

  for (const match of html.matchAll(/<button\b[^>]*>/gi)) {
    if (!/\btype\s*=\s*(["'])button\1/i.test(match[0])) reportError(`${source}: button needs type="button" (${match[0].slice(0, 100)})`);
  }

  for (const match of html.matchAll(/<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>/gi)) {
    checkUrl(match[2], filePath, "link");
    if (/\btarget\s*=\s*(["'])_blank\1/i.test(match[0]) && !/\brel\s*=\s*(["'])[^"']*\bnoreferrer\b/i.test(match[0])) {
      reportError(`${source}: target=_blank link must include rel="noreferrer" (${match[2]})`);
    }
    if (/\bdownload\s*=/i.test(match[0])) {
      reportError(`${source}: download attribute is not allowed on this source-only site (${match[2]})`);
    }
  }

  for (const match of html.matchAll(/<(?:link|script|img|source|video|audio|iframe)\b[^>]*(?:href|src|poster)\s*=\s*(["'])(.*?)\1[^>]*>/gi)) {
    checkUrl(match[2], filePath, "asset");
  }

  for (const match of html.matchAll(/<script\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1[^>]*>/gi)) {
    if (isExternalUrl(match[2])) reportError(`${source}: external runtime script dependency is not allowed: ${match[2]}`);
  }

  for (const match of html.matchAll(/<link\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>/gi)) {
    if (isExternalUrl(match[2]) && /\brel\s*=\s*(["'])[^"']*\bstylesheet\b/i.test(match[0])) {
      reportError(`${source}: external stylesheet dependency is not allowed: ${match[2]}`);
    }
  }

  for (const match of html.matchAll(/\bsrcset\s*=\s*(["'])(.*?)\1/gi)) {
    for (const candidate of match[2].split(",")) {
      const sourceUrl = candidate.trim().split(/\s+/, 1)[0];
      if (sourceUrl) checkUrl(sourceUrl, filePath, "asset");
    }
  }
}

function checkCssFile(filePath) {
  const css = readFileSync(filePath, "utf8");
  const source = displayPath(filePath);
  for (const match of css.matchAll(/url\(\s*(["']?)(.*?)\1\s*\)/gi)) {
    const value = match[2].trim();
    if (isExternalUrl(value)) {
      reportError(`${source}: external CSS asset dependency is not allowed: ${value}`);
    } else {
      checkUrl(value, filePath, "CSS asset");
    }
  }
  for (const match of css.matchAll(/@import\s+(?:url\()?\s*(["'])(.*?)\1/gi)) {
    checkUrl(match[2], filePath, "CSS import");
  }
}

function checkJsFile(filePath) {
  const javascript = readFileSync(filePath, "utf8");
  const source = displayPath(filePath);
  for (const match of javascript.matchAll(/(?:import|export)\s+(?:[^;]*?\s+from\s+)?(["'])(https?:)\1/gi)) {
    reportError(`${source}: external JavaScript dependency is not allowed: ${match[2]}`);
  }
}

const htmlFiles = [
  ...walk(pagesRoot, (filePath) => extname(filePath) === ".html"),
  ...walk(assetsRoot, (filePath) => extname(filePath) === ".html"),
].sort();
const cssFiles = walk(assetsRoot, (filePath) => extname(filePath) === ".css").sort();
const jsFiles = walk(assetsRoot, (filePath) => extname(filePath) === ".js").sort();
const assetFiles = walk(assetsRoot, (filePath) => [".svg", ".png", ".jpg", ".jpeg", ".webp", ".ico"].includes(extname(filePath))).sort();

if (htmlFiles.length === 0) reportError("pages/ contains no HTML files");
if (cssFiles.length === 0) reportError("site-assets/ contains no CSS files");
if (jsFiles.length === 0) reportError("site-assets/ contains no JavaScript files");

for (const filePath of htmlFiles) {
  counts.html += 1;
  checkHtmlFile(filePath);
}
for (const filePath of cssFiles) {
  counts.stylesheets += 1;
  checkCssFile(filePath);
}
for (const filePath of jsFiles) {
  counts.scripts += 1;
  checkJsFile(filePath);
}
counts.assets = assetFiles.length;

if (warnings.length > 0) {
  console.warn("Warnings:");
  warnings.forEach((warning) => console.warn(`  - ${warning}`));
}

console.log("KanaAI pages validation");
console.log(`  HTML pages:       ${counts.html}`);
console.log(`  CSS files:        ${counts.stylesheets}`);
console.log(`  JS files:         ${counts.scripts}`);
console.log(`  image assets:     ${counts.assets}`);
console.log(`  local references: ${counts.localReferences}`);
console.log(`  external links:   ${counts.externalLinks} (syntax checked; no network requests made)`);
console.log(`  page anchors:     ${counts.anchors}`);

if (errors.length > 0) {
  console.error("\nErrors:");
  errors.forEach((error) => console.error(`  - ${error}`));
  console.error(`\nValidation failed: ${errors.length} error(s).`);
  process.exitCode = 1;
} else {
  console.log("\nValidation passed: all local links and assets resolve.");
}
