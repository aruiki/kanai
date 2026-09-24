# GitHub Pages product site

The Japanese product page is maintained in [`site-assets/`](../site-assets/) and
published from the `gh-pages` branch. Its public URL is:

<https://aruiki.github.io/kanai/>

The page is intentionally separate from the development workbench. It is a
static, dependency-free product surface for explaining what KanaAI is, what is
implemented today, how local AI is bounded, and what the Windows beta does and
does not do.

## Local preview

From the repository root:

```sh
python3 -m http.server 8088 --directory site-assets
```

Then open <http://127.0.0.1:8088/>. The page validator checks local links and
required Japanese content before publication.

## Publication rules

- Do not add fake download buttons or claim that a Windows TSF IME is shipped.
- Do not bundle model weights, API keys, local profiles, or user text.
- State clearly that no Windows beta exists until the native TSF exit gates pass.
- Update the page whenever the README's capability table or TSF boundary changes.
- The `gh-pages` branch is generated from `site-assets/`; do not hand-edit the
  deployed copy without applying the change back to the source directory.
