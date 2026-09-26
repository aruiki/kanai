# GitHub Pages product site — NOT PUBLISHED (decided 2026-09-26)

> **Decision: KanaAI does not publish a public product website.**
> The overview, install steps, hashes, known limitations, and verification
> results live in **this repository and in the GitHub Release body**. There is no
> `gh-pages` deployment for this project.
>
> `site-assets/` is retained as an unused local draft. It is **not** the source of
> truth for any published statement, and nothing in it may be cited as a release
> claim. Do not spend work polishing it, and do not publish it without a new
> explicit user decision.

The Japanese product page draft is maintained in [`site-assets/`](../site-assets/).
It has never been published, and per the decision above it will not be.

## Local preview of the unused draft

From the repository root:

```sh
python3 -m http.server 8088 --directory site-assets
```

Then open <http://127.0.0.1:8088/>.

There is **no automated page validator in this repository**. The draft is checked
by reading it, not by a passing command. Do not write or repeat a claim that a
validator ran.

## Publication rules that still apply to the repository and the Release body

These were written for a website, but the obligation is unchanged now that the
information is published on GitHub instead. Wherever the summary, install steps,
or limitations are published:

- Do not add fake download buttons or claim that a Windows TSF IME is shipped.
- The published text must not contain API keys, local profiles, or user text.
- The planned AI release may describe a pinned, license-approved model/runtime
  only as an implementation candidate until the exact bytes, notices, SBOM,
  installer, and native failure/quality tests are verified. Do not imply that a
  candidate is already bundled or running.
- State clearly that no Windows beta exists until the native TSF exit gates pass.
- Update the published text whenever the README's capability table or TSF
  boundary changes.

## Unsigned beta publication (decided 2026-09-26)

The user decided a code-signing certificate is **not** required for the beta.
That removes the signing blocker but does not remove the disclosure duty. The
README, the in-package `README.txt`, and the GitHub Release body must together
state all of:

- the artifacts are **unsigned**, so Windows may show a SmartScreen or publisher
  warning, and the reader must **not** be told to disable SmartScreen, Smart App
  Control, antivirus, or enterprise policy;
- the exact **SHA-256** of each published file, the **source commit**, and the
  applicable licenses;
- the **verified vs unverified** split, stated as the installer test results
  actually were — including anything that failed;
- that the beta is **Mozc-baseline only and contains no local AI model or
  runtime** (user decision D-1), and must not be presented as an AI product;
- that a beta is **not** GOAL completion, and `.goal-complete` is not created.
