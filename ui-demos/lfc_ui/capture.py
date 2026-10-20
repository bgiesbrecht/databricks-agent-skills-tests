"""Finish a captured run: time between screenshots (metrics.yaml), GIFs, and for hand captures, redacted copies.

lfc_ui.wizard saves runs/<name>/png/NNN_<step>.png, already masked in the page, and calls this itself. Screenshots
taken by hand with the Chrome DevTools tools go to runs/<name>/clear/; finish those from the demo's folder:
    python -m lfc_ui.capture runs/<name> --secret <account-id> --secret <workspace-id>

Adapted from the lfc-faq notes (scripts/lfc_playwright/capture.py, e9db42b): the GIF writer is theirs.
"""

from __future__ import annotations

import argparse
import re
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import yaml
from .image_redact import redact_png
from PIL import Image

_MIN_FRAME_DURATION_MS = 400
_LAST_FRAME_DURATION_MS = 1_000
_MAX_FRAME_DURATION_MS = 5_000


def png_slug(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")


def write_gif(
    source_dir: Path,
    destination: Path,
    durations_by_name: dict[str, int] | None = None,
) -> None:
    """Write filename-ordered PNGs as an animated GIF."""
    pngs = sorted(source_dir.glob("*.png"))
    if not pngs:
        return
    frames: list[Image.Image] = []
    for png in pngs:
        with Image.open(png) as image:
            frames.append(image.convert("RGB"))
    durations = [
        min((durations_by_name or {}).get(png.name, _LAST_FRAME_DURATION_MS), _MAX_FRAME_DURATION_MS) for png in pngs
    ]  # a long wait (a CDC update) would overflow the GIF's 16-bit frame time; metrics.yaml keeps the real one
    destination.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        destination,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
    )
    for frame in frames:
        frame.close()


def write_run_gifs(directory: Path) -> None:
    """Regenerate a run's GIFs: one per PNG folder it has (png/ from the script; clear/ and redacted/ by hand)."""
    metrics_path = directory / "metrics.yaml"
    payload = (
        yaml.safe_load(metrics_path.read_text(encoding="utf-8"))
        if metrics_path.is_file()
        else {}
    )
    clicks = payload.get("clicks") if isinstance(payload, dict) else []
    durations = {
        str(click["after"]): max(
            _MIN_FRAME_DURATION_MS,
            round(float(click["wait_seconds"]) * 1_000),
        )
        for click in clicks or []
    }
    for folder in ("png", "clear", "redacted"):
        if (directory / folder).is_dir():
            write_gif(directory / folder, directory / f"{folder}.gif", durations)


def finish_run(directory: Path, secrets: Sequence[str], metadata: dict[str, Any] | None = None) -> None:
    """Write metrics.yaml (seconds between screenshots) and the GIFs. Script runs (png/) are masked in the page
    before each screenshot, so they need nothing more. Hand captures (clear/) get redacted copies: digit IDs such
    as the workspace ID, found by OCR, masked to their last four digits."""
    folder = "png" if (directory / "png").is_dir() else "clear"
    pngs = sorted((directory / folder).glob("*.png"))
    if folder == "clear":
        for png in pngs:
            redact_png(png, directory / "redacted" / png.name, secrets)
    clicks = [
        {
            "after": a.name,
            "until": b.name,
            "wait_seconds": round(b.stat().st_mtime - a.stat().st_mtime, 3),
        }
        for a, b in zip(pngs, pngs[1:])
    ]
    payload = dict(metadata or {})
    payload["clicks"] = clicks
    (directory / "metrics.yaml").write_text(
        yaml.safe_dump(payload, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    write_run_gifs(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory", type=Path, help="the run folder, runs/<name>")
    parser.add_argument("--secret", action="append", default=[], help="a digit ID to mask (repeatable)")
    parser.add_argument("--meta", action="append", default=[], metavar="KEY=VALUE", help="added to metrics.yaml")
    args = parser.parse_args()
    finish_run(args.directory, args.secret, dict(m.split("=", 1) for m in args.meta))
