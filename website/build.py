#!/usr/bin/env python3
"""Builds the Agent2 website into ./public from the fragments in ./src.

Every page shares one header and footer. Docs pages also get the sidebar,
an "On this page" list built from their <h2 id> headings, and prev/next links.

    python3 build.py          # writes public/**/index.html
"""
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).parent
SRC = ROOT / "src"
OUT = ROOT / "public"

REPO = "https://github.com/sekophungula/agent2"
ZIP = f"{REPO}/releases/latest/download/Agent2-macOS.zip"
VERSION = "0.1.1"

# (path, source fragment, nav key, title, description)
PAGES = [
    ("", "home.html", "home", "Agent2 — the middleman for your AI agents",
     "A macOS menu-bar app that gets Claude Code, Codex, Gemini and your API keys working together. Hold Control+Option and talk."),
    ("download/", "download.html", "download", "Download Agent2",
     "Download Agent2 for macOS, or build it from source."),
    ("changelog/", "changelog.html", "changelog", "Changelog — Agent2",
     "New features, improvements and fixes shipped in Agent2."),
    ("integrations/", "integrations.html", "integrations", "Integrations — Agent2",
     "The agents Agent2 works with and the apps you can link through Composio."),
]

# Docs, in sidebar order: (group, slug, title, blurb)
DOCS = [
    ("Start here", "", "What is Agent2?", "Who Agent2 is for and what it does."),
    ("Start here", "install", "Install", "Download, open and grant permissions."),
    ("Start here", "first-request", "Your first request", "Talk to Agent2 and watch it delegate."),
    ("Concepts", "source", "The source agent", "The agent Agent2 thinks with."),
    ("Concepts", "delegation", "Delegation", "How work is split across agents."),
    ("Concepts", "history", "History", "Markdown files you own."),
    ("Concepts", "autonomy", "Autonomy", "What agents may do on your Mac."),
    ("Agents", "supported-agents", "Supported agents", "CLIs, API keys and desktop apps."),
    ("Agents", "api-keys", "API keys", "Using Anthropic or OpenAI keys."),
    ("Apps", "composio", "Composio apps", "Link Gmail, Slack, GitHub and more."),
    ("Using Agent2", "voice", "Voice & hotkey", "Push-to-talk with ⌃ Control + ⌥ Option."),
    ("Using Agent2", "troubleshooting", "Troubleshooting", "Fixes for common problems."),
    ("Using Agent2", "build-from-source", "Build from source", "Compile Agent2 yourself."),
]

GITHUB_ICON = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>'
DOWNLOAD_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M8 2v8m0 0L4.5 6.5M8 10l3.5-3.5M2.5 13.5h11"/></svg>'


def header(active: str) -> str:
    def link(href, key, label):
        cls = ' class="on"' if key == active else ""
        return f'<a href="{href}"{cls}>{label}</a>'
    return f"""
  <header class="nav">
    <div class="nav-inner">
      <a class="brand" href="/"><img src="/assets/logo-green.svg" alt="" />Agent2</a>
      <nav class="links">
        {link("/docs/", "docs", "Docs")}
        {link("/integrations/", "integrations", "Integrations")}
        {link("/changelog/", "changelog", "Changelog")}
        {link("/download/", "download", "Download")}
      </nav>
      <div class="nav-cta">
        <a class="btn btn-line btn-sm gh" href="{REPO}">{GITHUB_ICON}<span data-stars>GitHub</span></a>
        <a class="btn btn-white btn-sm" href="/download/">{DOWNLOAD_ICON}Download</a>
        <button class="menu-btn" aria-label="Menu" aria-expanded="false" data-menu>☰</button>
      </div>
    </div>
    <nav class="mobile-links" data-mobile>
      <a href="/docs/">Docs</a><a href="/integrations/">Integrations</a><a href="/changelog/">Changelog</a><a href="/download/">Download</a><a href="{REPO}">GitHub</a>
    </nav>
  </header>"""


FOOTER = f"""
  <footer class="footer">
    <div class="frame">
      <div class="foot">
        <div><a class="brand" href="/"><img src="/assets/logo-green.svg" alt="" />Agent2</a><p>The middleman for your AI agents. A macOS menu-bar app.</p></div>
        <div><span class="label">Product</span><a href="/download/">Download</a><a href="/integrations/">Integrations</a><a href="/changelog/">Changelog</a></div>
        <div><span class="label">Docs</span><a href="/docs/">What is Agent2?</a><a href="/docs/install/">Install</a><a href="/docs/troubleshooting/">Troubleshooting</a></div>
        <div><span class="label">Source</span><a href="{REPO}">GitHub</a><a href="{REPO}/releases">Releases</a><a href="{REPO}/blob/main/LICENSE">MIT License</a></div>
      </div>
      <div class="legal"><span>© 2026 Shakatec</span><span class="sw">v{VERSION}</span></div>
    </div>
  </footer>"""

SCRIPT = """
  <script>
  (function () {
    var b = document.querySelector('[data-menu]'), m = document.querySelector('[data-mobile]');
    if (b && m) b.addEventListener('click', function () { var o = m.classList.toggle('open'); b.setAttribute('aria-expanded', o); });
    document.querySelectorAll('[data-copy]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var t = btn.closest('.cmd').querySelector('code').innerText;
        navigator.clipboard.writeText(t).then(function () { btn.textContent = 'Copied'; setTimeout(function () { btn.textContent = 'Copy'; }, 1400); });
      });
    });
    document.querySelectorAll('[data-tabs]').forEach(function (root) {
      var tabs = root.querySelectorAll('[data-tab]'), panes = root.querySelectorAll('[data-pane]');
      tabs.forEach(function (t) { t.addEventListener('click', function () {
        tabs.forEach(function (x) { x.classList.toggle('on', x === t); x.setAttribute('aria-selected', x === t); });
        panes.forEach(function (p) { p.hidden = p.dataset.pane !== t.dataset.tab; });
      }); });
    });
    var q = document.querySelector('[data-docsearch]');
    if (q) q.addEventListener('input', function () {
      var v = q.value.toLowerCase();
      document.querySelectorAll('.docs-nav a').forEach(function (a) { a.hidden = v && a.textContent.toLowerCase().indexOf(v) < 0; });
    });
    var s = document.querySelector('[data-stars]');
    if (s) fetch('https://api.github.com/repos/sekophungula/agent2').then(function (r) { return r.json(); })
      .then(function (d) { if (d.stargazers_count > 0) s.textContent = d.stargazers_count.toLocaleString(); }).catch(function () {});
  })();
  </script>"""


EXTERNAL_LINK = re.compile(r'<a\b([^>]*?)\bhref="(https?://[^"]+)"([^>]*)>')


def external_links(doc: str) -> str:
    """Links that leave agent2.shakatec.co.za open in a new tab.

    Direct file downloads (.zip) are left alone: they start a download
    without leaving the page, so a new tab would only flash open and close.
    """
    def fix(m):
        before, href, after = m.groups()
        attrs = before + after
        if "agent2.shakatec.co.za" in href or href.endswith(".zip") or "target=" in attrs:
            return m.group(0)
        return f'<a{before}href="{href}"{after} target="_blank" rel="noopener noreferrer">'
    return EXTERNAL_LINK.sub(fix, doc)


def page(title, desc, active, body, url):
    return external_links(_page(title, desc, active, body, url))


def _page(title, desc, active, body, url):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{html.escape(title)}</title>
  <meta name="description" content="{html.escape(desc)}" />
  <meta property="og:title" content="{html.escape(title)}" />
  <meta property="og:description" content="{html.escape(desc)}" />
  <meta property="og:image" content="https://agent2.shakatec.co.za/assets/og.png" />
  <meta property="og:url" content="https://agent2.shakatec.co.za/{url}" />
  <meta name="theme-color" content="#0b0b0b" />
  <link rel="icon" type="image/svg+xml" href="/assets/favicon.svg" />
  <link rel="icon" type="image/png" href="/assets/favicon.png" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet" />
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>{header(active)}
{body}
{FOOTER}
{SCRIPT}
</body>
</html>
"""


ICONS = json.loads((SRC / "icons.json").read_text())  # Simple Icons paths + brand colours


def icon(slug: str) -> str:
    """Inline brand logo. Near-black brand colours are drawn light so they show on the dark site."""
    i = ICONS[slug]
    r, g, b = (int(i["hex"][k:k + 2], 16) for k in (0, 2, 4))
    color = "#EDEDED" if max(r, g, b) < 90 else f"#{i['hex']}"
    return (f'<svg viewBox="0 0 24 24" role="img" aria-label="{i["title"]}" fill="{color}">'
            f'<path d="{i["path"]}"/></svg>')


def fill(text: str) -> str:
    text = re.sub(r"\{\{icon:([a-z0-9]+)\}\}", lambda m: icon(m.group(1)), text)
    return text.replace("{{ZIP}}", ZIP).replace("{{REPO}}", REPO).replace("{{VERSION}}", VERSION)


def slugify(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", re.sub(r"<[^>]+>", "", s).lower()).strip("-")


def docs_page(i: int) -> str:
    group, slug, title, blurb = DOCS[i]
    content = fill((SRC / "docs" / f"{slug or 'index'}.html").read_text())

    # Give every <h2> an id and collect them for "On this page".
    toc = []
    def add_id(m):
        text = m.group(1)
        hid = slugify(text)
        toc.append((hid, re.sub(r"<[^>]+>", "", text)))
        return f'<h2 id="{hid}">{text}</h2>'
    content = re.sub(r"<h2>(.*?)</h2>", add_id, content)

    nav, last = [], None
    for g, s, t, _ in DOCS:
        if g != last:
            nav.append(f'<span class="label">{g}</span>')
            last = g
        on = ' class="on"' if s == slug else ""
        nav.append(f'<a href="/docs/{s + "/" if s else ""}"{on}>{t}</a>')

    prev_l = next_l = ""
    if i > 0:
        p = DOCS[i - 1]
        prev_l = f'<a class="pn" href="/docs/{p[1] + "/" if p[1] else ""}"><span class="label">← Previous</span>{p[2]}</a>'
    if i < len(DOCS) - 1:
        n = DOCS[i + 1]
        next_l = f'<a class="pn next" href="/docs/{n[1]}/"><span class="label">Next →</span>{n[2]}</a>'

    toc_html = "".join(f'<a href="#{h}">{t}</a>' for h, t in toc)
    edit = f"{REPO}/edit/main/website/src/docs/{slug or 'index'}.html"
    body = f"""
  <main class="docs">
    <aside class="docs-side">
      <input class="docs-search" type="search" placeholder="Search docs" aria-label="Search docs" data-docsearch />
      <nav class="docs-nav">{''.join(nav)}</nav>
    </aside>
    <article class="docs-body">
      <span class="label g">// {group}</span>
      <h1>{title}</h1>
      <p class="docs-lead">{blurb}</p>
      <div class="prose">{content}</div>
      <div class="pn-row">{prev_l}{next_l}</div>
      <a class="edit" href="{edit}">Edit this page on GitHub →</a>
    </article>
    <aside class="docs-toc">{'<span class="label">On this page</span>' + toc_html if toc else ''}</aside>
  </main>"""
    return page(f"{title} — Agent2 Docs", blurb, "docs", body, f"docs/{slug + '/' if slug else ''}")


def main():
    for path, src, key, title, desc in PAGES:
        body = fill((SRC / src).read_text())
        out = OUT / path / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page(title, desc, key, body, path))
        print("wrote", out.relative_to(ROOT))
    for i, d in enumerate(DOCS):
        out = OUT / "docs" / d[1] / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(docs_page(i))
        print("wrote", out.relative_to(ROOT))
    nf = page("Not found — Agent2", "This page doesn't exist.", "", fill((SRC / "404.html").read_text()), "404")
    (OUT / "404.html").write_text(nf)
    print("wrote public/404.html")


if __name__ == "__main__":
    main()
