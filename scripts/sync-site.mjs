// site-assets is the publish source; pages/index.html is the repository preview.
import { readFileSync, writeFileSync } from 'node:fs';
const root = new URL('../', import.meta.url);
const html = readFileSync(new URL('site-assets/index.html', root), 'utf8');
writeFileSync(new URL('pages/index.html', root), html.replaceAll('href="kanai-mark.svg"', 'href="../site-assets/kanai-mark.svg"').replaceAll('src="kanai-mark.svg"', 'src="../site-assets/kanai-mark.svg"').replaceAll('href="landing.css"', 'href="../site-assets/landing.css"'));
