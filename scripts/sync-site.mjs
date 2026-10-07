// site-assets/ is the publish source; pages/ is the repository preview mirror.
// The mirror is a faithful copy of the whole tree so that relative links and
// the language subdirectory resolve exactly as they do on the published site.
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceRoot = join(repositoryRoot, 'site-assets');
const mirrorRoot = join(repositoryRoot, 'pages');

function walk(directory, root) {
  if (!existsSync(directory)) return [];
  const entries = [];
  for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const entryPath = join(directory, entry.name);
    if (entry.isDirectory()) entries.push(...walk(entryPath, root));
    else entries.push(relative(root, entryPath).replaceAll('\\', '/'));
  }
  return entries;
}

if (!existsSync(sourceRoot)) {
  console.error('site-assets/ is missing; nothing to sync.');
  process.exitCode = 1;
} else {
  const sources = walk(sourceRoot, sourceRoot);
  const mirrored = walk(mirrorRoot, mirrorRoot);
  mkdirSync(mirrorRoot, { recursive: true });

  let copied = 0;
  for (const entry of sources) {
    const target = join(mirrorRoot, entry);
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(join(sourceRoot, entry), target);
    copied += 1;
  }

  const stale = mirrored.filter((entry) => !sources.includes(entry));
  for (const entry of stale) rmSync(join(mirrorRoot, entry), { force: true });
  for (const entry of readdirSync(mirrorRoot, { withFileTypes: true })) {
    const entryPath = join(mirrorRoot, entry.name);
    if (entry.isDirectory() && statSync(entryPath).size === 0 && readdirSync(entryPath).length === 0) rmSync(entryPath, { recursive: true, force: true });
  }

  console.log(`pages/ mirrors site-assets/: ${copied} file(s) copied, ${stale.length} stale file(s) removed.`);
  if (stale.length > 0) console.log(`  removed: ${stale.join(', ')}`);
}
