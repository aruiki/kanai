#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const pagesRoot = join(repositoryRoot, "pages");
const assetsRoot = join(repositoryRoot, "site-assets");
const siteOrigin = "https://aruiki.github.io/kanai/";
const releaseVersion = "0.1.0-beta.2";
const canonicalOwners = new Map();
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
  // A link to a directory means the directory index, as it does on the server.
  const target = decoded.endsWith("/") ? `${decoded}index.html` : decoded;
  if (target.startsWith("/")) return resolve(repositoryRoot, target.slice(1));
  return resolve(dirname(sourceFile), target);
}

// Editors and copy/paste have previously mixed non-Japanese scripts into the
// Japanese copy (for example Arabic or Hangul characters that look like
// corruption rather than typos). Reject anything outside the ranges the site
// legitimately uses so that damage is caught by a command, not by a reader.
// The allowed set is deliberately narrow: accented Latin letters are not used on
// this site, so a stray "composicion"-style intrusion from an editor is caught.
const allowedScriptRanges = [
  [0x0000, 0x007f], [0x00a0, 0x00a0], [0x00a9, 0x00ae], [0x00b7, 0x00b7],
  [0x2000, 0x206f], [0x2190, 0x21ff],
  [0x2460, 0x24ff], [0x25a0, 0x27bf], [0x2e80, 0x30ff], [0x31f0, 0x31ff],
  [0x4e00, 0x9fff], [0xf900, 0xfaff], [0xfe30, 0xfe4f], [0xff00, 0xffef],
  [0x1f000, 0x1faff], [0x20000, 0x2fa1f],
];

function checkScriptSanity(text, sourceFile) {
  const source = displayPath(sourceFile);
  const unexpected = new Map();
  for (const character of text) {
    const code = character.codePointAt(0);
    if (allowedScriptRanges.some(([low, high]) => code >= low && code <= high)) continue;
    unexpected.set(character, (unexpected.get(character) || 0) + 1);
  }
  for (const [character, count] of unexpected) {
    reportError(`${source}: unexpected character U+${character.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")} (${character}) x${count} - wrong-script corruption, not a typo`);
  }
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

function pageLanguage(html) {
  const match = html.match(/<html\b[^>]*\blang\s*=\s*(["'])([a-zA-Z-]+)\1/i);
  return match ? match[2].toLowerCase() : "";
}

function pageTree(filePath) {
  const relativePath = displayPath(filePath).split("\\").join("/");
  return relativePath.startsWith("pages/") ? "pages" : "site-assets";
}

function pageKind(filePath) {
  const relativePath = displayPath(filePath).split("\\").join("/");
  const withinTree = relativePath.replace(/^(?:pages|site-assets)\//, "");
  if (withinTree === "index.html" || withinTree === "en/index.html") return "home";
  if (withinTree.endsWith("faq.html")) return "faq";
  return "interior";
}

function checkHtmlFile(filePath) {
  const html = readFileSync(filePath, "utf8");
  const source = displayPath(filePath);
  const ids = collectIds(html, filePath);
  checkAnchors(html, ids, filePath);
  const language = pageLanguage(html);
  const kind = pageKind(filePath);

  if (!/<!doctype\s+html>/i.test(html)) reportError(`${source}: missing HTML5 doctype`);
  if (!["ja", "en"].includes(language)) reportError(`${source}: html element must declare lang="ja" or lang="en"`);
  if (!/<title\b[^>]*>[^<]+<\/title>/i.test(html)) reportError(`${source}: missing non-empty title`);
  if (!/<main\b/i.test(html)) reportError(`${source}: missing main landmark`);
  if (!/<h1\b/i.test(html)) reportError(`${source}: missing h1`);
  if (!/class\s*=\s*(["'])skip-link\1/i.test(html)) reportError(`${source}: missing skip link`);
  checkScriptSanity(html, filePath);

  const title = (html.match(/<title\b[^>]*>([^<]+)<\/title>/i) || [])[1] || "";
  const description = (html.match(/<meta\b[^>]*\bname\s*=\s*(["'])description\1[^>]*\bcontent\s*=\s*(["'])(.*?)\2/i) || [])[3] || "";
  if (title.length > 70) reportWarning(`${source}: title is ${title.length} characters; search results usually truncate past 70`);
  if (description.length === 0) reportError(`${source}: missing description`);
  if (description.length > 160) reportWarning(`${source}: description is ${description.length} characters; search results usually truncate past 160`);

  // Honest-disclosure phrases. Every published page must pin the release and say
  // the beta is unsigned and unfinished, in the language of that page. The home
  // page additionally carries the measured-result and size statements.
  const phrases = language === "en"
    ? ["Mozc", "Windows", `v${releaseVersion}`, "unsigned", "not a completed product"]
    : ["Mozc", "Windows", `v${releaseVersion}`, "未署名", "未完成"];
  if (kind === "home" && language === "ja") {
    phrases.push("変換結果は変わりません", "ダウンロード", "FAQ", "約1.1 GB");
  }
  for (const phrase of phrases) {
    if (!html.includes(phrase)) reportError(`${source}: required product content missing: ${phrase}`);
  }

  if ((html.match(/<h1\b/gi) || []).length !== 1) reportError(`${source}: expected exactly one h1`);

  const canonicals = [...html.matchAll(/<link\b[^>]*>/gi)]
    .filter((match) => /\brel\s*=\s*(["'])canonical\1/i.test(match[0]))
    .map((match) => (match[0].match(/\bhref\s*=\s*(["'])(.*?)\1/i) || [])[2] || "");
  if (canonicals.length !== 1) reportError(`${source}: expected exactly one canonical link, found ${canonicals.length}`);
  for (const canonical of canonicals) {
    if (!canonical.startsWith(siteOrigin)) reportError(`${source}: canonical must stay on ${siteOrigin} (found ${canonical})`);
    else canonicalOwners.set(canonical, (canonicalOwners.get(canonical) || []).concat(`${pageTree(filePath)}:${displayPath(filePath)}`));
  }

  for (const property of ["og:title", "og:description", "og:url", "og:image"]) {
    if (!html.includes(`property="${property}"`)) reportError(`${source}: missing ${property} (required for social sharing)`);
  }
  if (!/name\s*=\s*(["'])twitter:card\1/i.test(html)) reportError(`${source}: missing twitter:card`);
  if (!/hreflang\s*=\s*(["'])x-default\1/i.test(html)) reportWarning(`${source}: missing an hreflang x-default alternate`);

  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
  if (blocks.length === 0) reportError(`${source}: expected at least one structured-data block`);
  const types = [];
  for (const match of blocks) {
    try {
      const data = JSON.parse(match[1]);
      types.push(data["@type"]);
      if (data["@type"] === "SoftwareApplication" && data.softwareVersion !== releaseVersion) {
        reportError(`${source}: incorrect software metadata`);
      }
      if (data["@type"] === "FAQPage" && !(Array.isArray(data.mainEntity) && data.mainEntity.length > 0)) {
        reportError(`${source}: FAQPage structured data has no questions`);
      }
    } catch { reportError(`${source}: invalid structured data`); }
  }
  if (kind === "home" && !types.includes("SoftwareApplication")) reportError(`${source}: home page must expose SoftwareApplication structured data`);
  if (kind === "faq" && !types.includes("FAQPage")) reportError(`${source}: FAQ page must expose FAQPage structured data`);
  if (kind === "interior" && !types.includes("BreadcrumbList")) reportError(`${source}: interior page must expose BreadcrumbList structured data`);

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

// Two pages in the same published tree claiming one canonical URL means one of
// them will be dropped from the index. The pages/ mirror shares URLs with
// site-assets/ by design, so uniqueness is enforced per tree.
for (const [canonical, owners] of canonicalOwners) {
  const byTree = new Map();
  for (const owner of owners) {
    const tree = owner.split(":", 1)[0];
    byTree.set(tree, (byTree.get(tree) || []).concat(owner));
  }
  for (const [, list] of byTree) {
    if (list.length > 1) reportError(`canonical ${canonical} is claimed by ${list.length} pages in one tree: ${list.join(", ")}`);
  }
}

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
