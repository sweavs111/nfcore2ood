#!/usr/bin/env python3

"""Generate the nf-core landing page (public/index.html) from deployed apps.

The individual pipeline apps under apps/sys ship with `category: ""` in
their manifest.yml so they're deliberately hidden from the dashboard's main
nav/grid (see OodApp#should_appear_in_nav?, which requires a non-empty
category) -- they're meant to be reached only through this landing page,
not to clutter the top-level app list. This script is what keeps that page
in sync with whatever pipeline apps actually exist, by reading each one's
own manifest.yml (name, subcategory, description) rather than hand-editing
static HTML.

Usage::

    generate_landing_page.py <apps_dir> <output_html>

<apps_dir> is scanned non-recursively for direct subdirectories containing
a manifest.yml with role: batch_connect (e.g. /var/www/ood/apps/sys) --
matching exactly what OOD's SysRouter itself scans, so this always reflects
what the dashboard could serve. <output_html> is written as a static,
self-contained HTML page (no external requests) meant to live at
apps/sys/nf-core/public/index.html, served directly by nginx's Passenger
"alias .../public" rule -- no backend app process required.
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

import yaml

# Subcategories that don't read well through str.title() (e.g. "rnaseq" ->
# "Rnaseq" instead of "RNAseq"). Matched against pipeline2subcategory.tsv;
# anything else falls back to .title().
SUBCATEGORY_DISPLAY_NAMES = {
    "rnaseq": "RNAseq",
    "singlecell": "Single-cell",
}

MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")


def display_subcategory(subcategory: str) -> str:
    return SUBCATEGORY_DISPLAY_NAMES.get(subcategory, subcategory.title())


def plain_text(markdown: str) -> str:
    """Strip manifest description down to plain text for a static <p>.

    Manifest descriptions are rendered as markdown elsewhere in the
    dashboard, but this is a plain static page with no markdown renderer,
    so `[label](url)` would otherwise show up as literal brackets.
    """
    return MARKDOWN_LINK_RE.sub(r"\1", markdown)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("apps_dir", help="Directory to scan for pipeline apps (e.g. /var/www/ood/apps/sys)")
    parser.add_argument("output_html", help="Path to write the generated index.html to")
    parser.add_argument(
        "--dashboard-root",
        default="/pun/sys/dashboard",
        help="Base URL of the OnDemand dashboard app (default: %(default)s)",
    )
    return parser.parse_args()


def load_pipeline_apps(apps_dir: Path) -> list[dict]:
    """Direct children of apps_dir that are generated nf-core pipeline apps.

    Mirrors SysRouter.apps' own (non-recursive) `children` scan, so this
    only ever lists apps the dashboard could actually serve. Matched on the
    `nf-core-` slug prefix nf2ood always gives generated apps, not just
    `role: batch_connect` -- other unrelated sys apps (e.g. bc_desktop) are
    batch_connect too and would otherwise get swept in here alongside them.
    """
    apps = []
    for child in sorted(apps_dir.iterdir()):
        manifest_path = child / "manifest.yml"
        if not child.is_dir() or not manifest_path.is_file() or not child.name.startswith("nf-core-"):
            continue
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
        if manifest.get("role") != "batch_connect":
            continue
        apps.append(
            {
                "slug": child.name,
                "name": str(manifest.get("name", child.name)),
                "subcategory": str(manifest.get("subcategory", "")) or "other",
                "description": str(manifest.get("description", "")).strip(),
            }
        )
    return apps


def group_by_subcategory(apps: list[dict]) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = {}
    for app in apps:
        groups.setdefault(app["subcategory"], []).append(app)
    return dict(sorted(groups.items()))


def render_html(groups: dict[str, list[dict]], dashboard_root: str) -> str:
    sections = []
    for subcategory, apps in groups.items():
        cards = []
        for app in sorted(apps, key=lambda a: a["name"]):
            href = f"{dashboard_root}/apps/show/{html.escape(app['slug'])}"
            description = html.escape(plain_text(app["description"])).replace("\n", " ")
            cards.append(
                f"""      <a class="card" href="{href}">
        <h3>{html.escape(app['name'])}</h3>
        <p>{description}</p>
      </a>"""
            )
        sections.append(
            f"""    <section>
      <h2>{html.escape(display_subcategory(subcategory))}</h2>
      <div class="grid">
{chr(10).join(cards)}
      </div>
    </section>"""
        )

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nf-core Pipelines</title>
<style>
  :root {{
    --bg: #f7f7f8; --fg: #1b1c1e; --muted: #5b5f66;
    --card-bg: #ffffff; --card-border: #e3e4e7; --accent: #1f8f5f;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #17181a; --fg: #eceef0; --muted: #9aa0a8;
      --card-bg: #212327; --card-border: #34363a; --accent: #4fd497;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 2.5rem 1.5rem 4rem; background: var(--bg); color: var(--fg);
    font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }}
  header {{ max-width: 960px; margin: 0 auto 2.5rem; }}
  header a {{ color: var(--muted); text-decoration: none; font-size: 0.9rem; }}
  header a:hover {{ text-decoration: underline; }}
  h1 {{ margin: 0.75rem 0 0.25rem; font-size: 1.9rem; }}
  header p {{ color: var(--muted); margin: 0; }}
  main {{ max-width: 960px; margin: 0 auto; }}
  section {{ margin-bottom: 2.25rem; }}
  h2 {{
    font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.06em;
    color: var(--muted); margin: 0 0 0.75rem;
  }}
  .grid {{
    display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 0.9rem;
  }}
  .card {{
    display: block; padding: 1rem 1.1rem; background: var(--card-bg);
    border: 1px solid var(--card-border); border-radius: 10px;
    text-decoration: none; color: inherit; transition: border-color 0.15s ease;
  }}
  .card:hover {{ border-color: var(--accent); }}
  .card h3 {{ margin: 0 0 0.35rem; font-size: 1.05rem; color: var(--accent); }}
  .card p {{ margin: 0; font-size: 0.88rem; color: var(--muted); line-height: 1.4; }}
</style>
</head>
<body>
  <header>
    <a href="{dashboard_root}">&larr; Back to dashboard</a>
    <h1>nf-core Pipelines</h1>
    <p>Nextflow pipelines from <a href="https://nf-co.re" style="color:inherit">nf-co.re</a>, ready to launch as batch jobs.</p>
  </header>
  <main>
{chr(10).join(sections)}
  </main>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    apps_dir = Path(args.apps_dir)
    if not apps_dir.is_dir():
        raise SystemExit(f"generate_landing_page: not a directory: {apps_dir}")

    apps = load_pipeline_apps(apps_dir)
    if not apps:
        raise SystemExit(f"generate_landing_page: no batch_connect pipeline apps found under {apps_dir}")

    groups = group_by_subcategory(apps)
    output_html = render_html(groups, args.dashboard_root.rstrip("/"))

    output_path = Path(args.output_html)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(output_html, encoding="utf-8")
    print(f"Wrote {output_path} ({len(apps)} pipelines, {len(groups)} groups)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI error path
        sys.stderr.write(f"generate_landing_page: error: {exc}\n")
        raise SystemExit(1)
