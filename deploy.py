#!/usr/bin/env python3
"""Update one application's image version in the homelab checkout."""

import re
import sys
from pathlib import Path

APP_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,40})$")
COMPONENT_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,40})$")
DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


def update_image(text: str, *, digest: str, tag: str, component: str = "image") -> str:
    lines = text.splitlines(keepends=True)
    in_image = False
    image_indent = None
    saw_digest = False
    saw_tag = False
    out = []
    for line in lines:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if in_image and stripped and not stripped.startswith("#") and indent <= image_indent:
            in_image = False
        key_match = re.match(rf"{re.escape(component)}:\s*(#.*)?$", stripped)
        selected = key_match and (indent == 0 if component == "image" else True)
        if not in_image and selected:
            in_image = True
            image_indent = indent
            out.append(line)
            continue
        if in_image and re.match(r"digest:\s*", stripped):
            saw_digest = True
            newline = "\n" if line.endswith("\n") else ""
            out.append(f"{' ' * indent}digest: {digest}{newline}")
            continue
        if in_image and re.match(r"tag:\s*", stripped):
            saw_tag = True
            newline = "\n" if line.endswith("\n") else ""
            quote = '"' if '"' in stripped else ""
            out.append(f"{' ' * indent}tag: {quote}{tag}{quote}{newline}")
            continue
        out.append(line)
    if not saw_digest or not saw_tag:
        raise SystemExit(f"{component}.tag and {component}.digest must both exist in the values file")
    return "".join(out)


def main() -> None:
    if len(sys.argv) not in (5, 6):
        raise SystemExit("usage: deploy.py <checkout> <app> <image_version> <git_sha> [component]")
    checkout, app, version, git_sha = sys.argv[1:5]
    component = sys.argv[5] if len(sys.argv) == 6 and sys.argv[5] else "image"
    if not APP_RE.match(app):
        raise SystemExit(f"refusing app name {app!r}")
    if not COMPONENT_RE.match(component):
        raise SystemExit(f"refusing component name {component!r}")
    if not re.match(r"^[0-9a-f]{40}$", git_sha):
        raise SystemExit("git_sha must be a 40-character commit id")
    if DIGEST_RE.match(version):
        digest, tag = version, git_sha
    elif TAG_RE.match(version):
        digest, tag = '""', version
    else:
        raise SystemExit("image_version must be a sha256 digest or an image tag")

    paths = [Path(checkout) / "deploy" / app / "values.yaml"]
    chart = Path(checkout) / "charts" / app / "values.yaml"
    if chart.exists():
        paths.append(chart)
    if not paths[0].is_file():
        raise SystemExit(f"missing {paths[0]}")

    changed = False
    for path in paths:
        original = path.read_text()
        updated = update_image(original, digest=digest, tag=tag, component=component)
        if updated != original:
            path.write_text(updated)
            changed = True
            print(f"updated {path}")
    if not changed:
        print("image version already matches; nothing to commit")
        return
    print(f"ready {app} component={component} tag={tag} digest={digest}")


if __name__ == "__main__":
    main()
