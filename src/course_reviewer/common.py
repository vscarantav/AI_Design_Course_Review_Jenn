from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any


def write_json(value: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_slug(value: str, max_length: int = 60) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-")
    return value[:max_length].rstrip("-") or "item"


def normalized_key(value: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", "", (value or "").lower())


def relative_unix(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def unique_directory(desired: Path) -> Path:
    candidate = desired
    suffix = 2
    while candidate.exists():
        candidate = desired.with_name(f"{desired.name}-{suffix}")
        suffix += 1
    candidate.mkdir(parents=True)
    return candidate


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def child_text(node: Any, name: str) -> str | None:
    for child in list(node):
        if local_name(child.tag) == name:
            return "".join(child.itertext()).strip()
    return None


def finding_filename(criterion_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", criterion_id).strip("-") + ".json"
