"""Shared Playwright screenshot, click timing, and PNG redaction.

Copied from the lfc-faq notes (scripts/lfc_playwright/capture.py, e9db42b). Changed: the redaction import, and
DemoCapture takes the folder to write to (default runs/<pipeline>), so captures land in a gitignored place.
"""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

import yaml
from .image_redact import redact_png
from PIL import Image
from playwright.sync_api import Locator, Page

_MIN_FRAME_DURATION_MS = 400
_LAST_FRAME_DURATION_MS = 1_000


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
        (durations_by_name or {}).get(png.name, _LAST_FRAME_DURATION_MS) for png in pngs
    ]
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
    """Regenerate clear/redacted GIFs for an existing captured run."""
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
    write_gif(directory / "clear", directory / "clear.gif", durations)
    write_gif(directory / "redacted", directory / "redacted.gif", durations)


class SequentialScreenshots:
    def __init__(
        self,
        directory: Path,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.directory = directory
        self.clear_dir = directory / "clear"
        self._n = 0
        self._clock = clock
        self._clicks: list[dict[str, Any]] = []
        self._metadata: dict[str, Any] = {}
        self._last_png: str | None = None
        self._last_at: float | None = None
        self.clear_dir.mkdir(parents=True, exist_ok=True)

    def next_path(self, label: str) -> Path:
        self._n += 1
        return self.clear_dir / f"{self._n:03d}_{png_slug(label)}.png"

    def record_click(self, png: Path, name: str) -> None:
        now = self._clock()
        filename = png.name
        if self._last_png is not None and self._last_at is not None:
            self._clicks.append(
                {
                    "after": self._last_png,
                    "until": filename,
                    "name": name,
                    "wait_seconds": round(now - self._last_at, 3),
                }
            )
            self._write()
        self._last_png = filename
        self._last_at = now

    def _write(self) -> None:
        payload = dict(self._metadata)
        payload["clicks"] = self._clicks
        (self.directory / "metrics.yaml").write_text(
            yaml.safe_dump(payload, sort_keys=False, allow_unicode=True),
            encoding="utf-8",
        )

    def finish(self, metadata: dict[str, Any] | None = None) -> None:
        self._metadata.update(metadata or {})
        self._write()
        write_run_gifs(self.directory)


class DemoCapture:
    def __init__(
        self,
        pipeline_name: str,
        redact_secrets: Sequence[str],
        directory: Path | None = None,
    ) -> None:
        pipeline_dir = directory or Path("runs") / pipeline_name
        self._shots = SequentialScreenshots(pipeline_dir)
        self._redacted_dir = pipeline_dir / "redacted"
        self._secrets = tuple(redact_secrets)

    def shot(self, target: Page, name: str) -> None:
        png = self._shots.next_path(name)
        target.screenshot(path=str(png))
        self._shots.record_click(png, name=name)
        self._after_clear(png)

    def click(self, locator: Locator, name: str) -> None:
        png = self._shots.next_path(name)
        locator.page.screenshot(path=str(png))
        locator.click()
        self._shots.record_click(png, name=name)
        self._after_clear(png)

    def _after_clear(self, png: Path) -> None:
        redact_png(png, self._redacted_dir / png.name, self._secrets)

    def finish(self, metadata: dict[str, Any] | None = None) -> None:
        self._shots.finish(metadata)
