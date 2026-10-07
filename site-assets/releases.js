// Refresh only release labels; capability descriptions remain dated and sourced.
// Failure leaves the static guide and the /releases/latest links fully usable.
(async () => {
  const base = 'https://github.com/aruiki/KotoriIME-japanese-';
  try {
    const response = await fetch('https://api.github.com/repos/aruiki/KotoriIME-japanese-/releases/latest', {
      credentials: 'omit', signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) return;
    const release = await response.json();
    if (release.draft || release.prerelease || !/^v\d+\.\d+\.\d+$/.test(release.tag_name)) return;
    const url = new URL(release.html_url);
    if (url.origin !== 'https://github.com' || !url.href.startsWith(`${base}/releases/tag/`)) return;
    document.querySelectorAll('[data-stable-version]').forEach((label) => { label.textContent = release.tag_name; });
    const container = document.getElementById('latest-release');
    if (!container) return;
    const link = document.createElement('a');
    link.href = url.href;
    link.textContent = `${document.documentElement.lang === 'en' ? 'Latest stable release' : '最新の公開版'}: ${release.tag_name} →`;
    container.replaceChildren(link);
  } catch { /* Public API unavailable: use the working static fallback. */ }
})();
