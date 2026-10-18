"""Redact known digit secrets in PNGs, keeping the last four digits visible.

Copied from the lfc-faq notes (scripts/lfc_image_redact.py, e9db42b), unchanged apart from this note.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw
from pytesseract import Output, image_to_data

_NON_DIGIT = re.compile(r"\D")
_OCR_SCALE = 2
_OCR_PSMS = (6, 11)


@dataclass(frozen=True)
class OcrWord:
    text: str
    left: int
    top: int
    width: int
    height: int
    line: tuple[int, int, int]
    order: int


@dataclass(frozen=True)
class MaskBox:
    left: int
    top: int
    width: int
    height: int


def digits_only(value: str) -> str:
    return _NON_DIGIT.sub("", value)


def keep_last_digits(value: str, n: int = 4) -> str:
    digits = digits_only(value)
    if n <= 0:
        return ""
    return digits[-n:]


def prefix_mask_width(width: int, digit_count: int, keep_last: int = 4) -> int:
    if width <= 0 or digit_count <= 0:
        return 0
    keep = min(keep_last, digit_count)
    if keep >= digit_count:
        return 0
    return int(width * (digit_count - keep) / digit_count)


def mask_boxes_for_secret(
    words: Sequence[OcrWord], secret: str, *, keep_last: int = 4
) -> list[MaskBox]:
    secret_digits = digits_only(secret)
    if not secret_digits:
        return []
    boxes: list[MaskBox] = []
    lines: dict[tuple[int, int, int], list[OcrWord]] = {}
    for word in words:
        lines.setdefault(word.line, []).append(word)
    for line_words in lines.values():
        ordered = sorted(line_words, key=lambda word: word.order)
        boxes.extend(_line_secret_boxes(ordered, secret_digits, keep_last))
    return boxes


def _line_secret_boxes(
    words: Sequence[OcrWord], secret_digits: str, keep_last: int
) -> list[MaskBox]:
    digit_spans: list[tuple[OcrWord, int, int]] = []
    joined = ""
    for word in words:
        digits = digits_only(word.text)
        if not digits:
            continue
        start = len(joined)
        joined += digits
        digit_spans.append((word, start, len(joined)))
    boxes: list[MaskBox] = []
    search_from = 0
    while True:
        found_at = joined.find(secret_digits, search_from)
        if found_at < 0:
            break
        secret_end = found_at + len(secret_digits)
        covering = [
            word
            for word, start, end in digit_spans
            if start < secret_end and end > found_at
        ]
        box = _union_box(covering)
        if box is not None:
            mask_w = prefix_mask_width(box.width, len(secret_digits), keep_last)
            if mask_w > 0 and box.height > 0:
                boxes.append(MaskBox(box.left, box.top, mask_w, box.height))
        search_from = found_at + 1
    return boxes


def _union_box(words: Sequence[OcrWord]) -> MaskBox | None:
    if not words:
        return None
    left = min(word.left for word in words)
    top = min(word.top for word in words)
    right = max(word.left + word.width for word in words)
    bottom = max(word.top + word.height for word in words)
    return MaskBox(left, top, right - left, bottom - top)


def _ocr_words(image: Image.Image, psm: int) -> list[OcrWord]:
    data = image_to_data(image, output_type=Output.DICT, config=f"--psm {psm}")
    words: list[OcrWord] = []
    texts: list[str] = data["text"]
    for index, raw in enumerate(texts):
        if not raw.strip():
            continue
        words.append(
            OcrWord(
                text=raw,
                left=int(data["left"][index]),
                top=int(data["top"][index]),
                width=int(data["width"][index]),
                height=int(data["height"][index]),
                line=(
                    int(data["block_num"][index]),
                    int(data["par_num"][index]),
                    int(data["line_num"][index]),
                ),
                order=int(data["word_num"][index]),
            )
        )
    return words


def redact_png(
    src: Path,
    dest: Path,
    secrets: Sequence[str],
    *,
    keep_last: int = 4,
) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    secret_digits = tuple(
        digits_only(secret) for secret in secrets if digits_only(secret)
    )
    image = Image.open(src).convert("RGB")
    if secret_digits:
        ocr_image = image.resize(
            (image.width * _OCR_SCALE, image.height * _OCR_SCALE),
            Image.Resampling.LANCZOS,
        )
        words: list[OcrWord] = []
        for psm in _OCR_PSMS:
            words.extend(_ocr_words(ocr_image, psm))
        draw = ImageDraw.Draw(image)
        for secret in secret_digits:
            for box in mask_boxes_for_secret(words, secret, keep_last=keep_last):
                left = box.left // _OCR_SCALE
                top = box.top // _OCR_SCALE
                width = max(1, box.width // _OCR_SCALE)
                height = max(1, box.height // _OCR_SCALE)
                draw.rectangle(
                    (left, top, left + width, top + height),
                    fill="black",
                )
    image.save(dest)
