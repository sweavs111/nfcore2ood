#!/usr/bin/env python3

"""Render the "nf-core Pipelines" landing page from generated OOD apps.

Scans an nf2ood --output directory for app manifests with `role:
batch_connect` (i.e. apps nf2ood itself generated, as opposed to the
landing page app or anything else that might share the output directory),
groups them by subcategory, and writes a small static Open OnDemand app
(manifest.yml + public/index.html + icon.png) that links to each one. Since
it scans the output directory rather than taking an explicit app list, it
reflects whatever apps currently exist there -- run it again after any
nf2ood run (including a filtered one) and it picks up added/removed apps
automatically.

Usage::

    gen_landing_page.py OUTPUT_DIR LANDING_APP_DIR URL_PREFIX TEMPLATE_DIR ICON_PATH
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

SECTION_PLACEHOLDER = "__SECTIONS__"

# Subcategory slugs (as used in pipeline2subcategory.tsv) that don't read
# well under a plain .title() call.
SUBCATEGORY_DISPLAY_OVERRIDES = {
    "rnaseq": "RNAseq",
    "singlecell": "Single Cell",
}

MANIFEST_NAME_RE = re.compile(r'^name:\s*"?([^"\n]+?)"?\s*$', re.MULTILINE)
MANIFEST_SUBCATEGORY_RE = re.compile(r'^subcategory:\s*"?([^"\n]*?)"?\s*$', re.MULTILINE)
MANIFEST_ROLE_RE = re.compile(r'^role:\s*(\S+)\s*$', re.MULTILINE)


def display_subcategory(subcategory: str) -> str:
    return SUBCATEGORY_DISPLAY_OVERRIDES.get(subcategory, subcategory.replace("_", " ").title())


def version_sort_key(version: str) -> list[tuple[int, object]]:
    key: list[tuple[int, object]] = []
    for part in re.split(r"[.\-]", version):
        key.append((0, int(part)) if part.isdigit() else (1, part))
    return key


def parse_app_manifest(manifest_path: Path) -> dict[str, str] | None:
    # Only apps nf2ood itself generated (role: batch_connect) become cards;
    # this is also what keeps the landing page from listing itself on a
    # re-run, since its own manifest has no role field.
    text = manifest_path.read_text(encoding="utf-8")
    role_match = MANIFEST_ROLE_RE.search(text)
    if not role_match or role_match.group(1) != "batch_connect":
        return None

    name_match = MANIFEST_NAME_RE.search(text)
    if not name_match:
        return None

    # customize_generated_app renders manifest name as "<slug> <version>".
    slug, _, version = name_match.group(1).partition(" ")
    if not version:
        return None

    subcategory_match = MANIFEST_SUBCATEGORY_RE.search(text)
    subcategory = (subcategory_match.group(1) if subcategory_match else "").strip() or "bioinformatics"

    return {"slug": slug, "version": version, "subcategory": subcategory}


def discover_apps(output_dir: Path) -> list[dict[str, str]]:
    apps = []
    for manifest_path in sorted(output_dir.glob("*/manifest.yml")):
        parsed = parse_app_manifest(manifest_path)
        if parsed is None:
            continue
        parsed["app_slug"] = manifest_path.parent.name
        apps.append(parsed)
    return apps


def render_card(entry: dict[str, str], url_prefix: str) -> str:
    return (
        f'      <a class="card" href="{url_prefix}/{entry["app_slug"]}">\n'
        f'        <h3>{entry["slug"]} {entry["version"]}</h3>\n'
        f'        <p>Launch the nf-core pipeline nf-core-{entry["slug"]} version '
        f'{entry["version"]} through Open OnDemand.</p>\n'
        f'      </a>'
    )


def render_sections(apps: list[dict[str, str]], url_prefix: str) -> str:
    if not apps:
        return '    <p style="color:var(--muted)">No pipelines are available yet.</p>'

    by_subcategory: dict[str, list[dict[str, str]]] = {}
    for app in apps:
        by_subcategory.setdefault(app["subcategory"], []).append(app)

    sections = []
    for subcategory in sorted(by_subcategory):
        entries = sorted(
            by_subcategory[subcategory],
            key=lambda a: (a["slug"], version_sort_key(a["version"])),
        )
        cards = "\n".join(render_card(entry, url_prefix) for entry in entries)
        sections.append(
            "    <section>\n"
            f"      <h2>{display_subcategory(subcategory)}</h2>\n"
            '      <div class="grid">\n'
            f"{cards}\n"
            "      </div>\n"
            "    </section>"
        )

    return "\n".join(sections)


def main() -> int:
    if len(sys.argv) != 6:
        sys.stderr.write(
            "usage: gen_landing_page.py OUTPUT_DIR LANDING_APP_DIR URL_PREFIX "
            "TEMPLATE_DIR ICON_PATH\n"
        )
        return 1

    output_dir = Path(sys.argv[1])
    landing_app_dir = Path(sys.argv[2])
    url_prefix = sys.argv[3].rstrip("/")
    template_dir = Path(sys.argv[4])
    icon_path = Path(sys.argv[5])

    template_html_path = template_dir / "index.template.html"
    template_html = template_html_path.read_text(encoding="utf-8")
    if SECTION_PLACEHOLDER not in template_html:
        sys.stderr.write(f"gen_landing_page: {template_html_path} is missing {SECTION_PLACEHOLDER}\n")
        return 1

    apps = discover_apps(output_dir)
    rendered_html = template_html.replace(SECTION_PLACEHOLDER, render_sections(apps, url_prefix))

    public_dir = landing_app_dir / "public"
    public_dir.mkdir(parents=True, exist_ok=True)
    (public_dir / "index.html").write_text(rendered_html, encoding="utf-8")
    shutil.copyfile(template_dir / "manifest.yml", landing_app_dir / "manifest.yml")
    shutil.copyfile(icon_path, landing_app_dir / "icon.png")

    sys.stderr.write(f"gen_landing_page: wrote {len(apps)} app card(s) to {landing_app_dir}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI error path
        sys.stderr.write(f"gen_landing_page: error: {exc}\n")
        raise SystemExit(1)
