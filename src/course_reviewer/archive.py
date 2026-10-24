from __future__ import annotations

import re
import shutil
import stat
import zipfile
from pathlib import Path, PurePosixPath

from .common import is_within


_INVALID_WINDOWS = re.compile(r'[<>:"|?*\x00-\x1f]')
_RESERVED_WINDOWS = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", re.I)


def safe_archive_relative_path(name: str) -> Path:
    parts: list[str] = []
    for part in name.replace("\\", "/").split("/"):
        if not part:
            continue
        if part in {".", ".."}:
            parts.append(part)
            continue
        safe = _INVALID_WINDOWS.sub("_", part).rstrip(". ") or "_"
        if _RESERVED_WINDOWS.match(safe):
            safe = "_" + safe
        parts.append(safe)
    return Path(*parts)


def expand_safe_archive(
    archive_path: Path,
    destination: Path,
    max_entries: int = 25_000,
    max_uncompressed_bytes: int = 2_147_483_648,
    collision_policy: str = "reject",
) -> list[dict[str, str]]:
    destination.mkdir(parents=True, exist_ok=True)
    owners: dict[str, str] = {}
    collisions: list[dict[str, str]] = []
    total = 0
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        if len(infos) > max_entries:
            raise ValueError(f"Archive has {len(infos)} entries; limit is {max_entries}.")
        for info in infos:
            total += info.file_size
            if total > max_uncompressed_bytes:
                raise ValueError(f"Archive expands beyond the {max_uncompressed_bytes}-byte safety limit.")
            if info.compress_size and info.file_size > 1_000_000 and info.file_size / info.compress_size > 500:
                raise ValueError(f"Archive entry has a suspicious compression ratio: {info.filename}.")
            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise ValueError(f"Symbolic links are not allowed in archives: {info.filename}.")
            posix = PurePosixPath(info.filename.replace("\\", "/"))
            if posix.is_absolute() or re.match(r"^[A-Za-z]:", info.filename):
                raise ValueError(f"Unsafe absolute archive path: {info.filename}.")
            relative = safe_archive_relative_path(info.filename)
            target = (destination / relative).resolve()
            if not is_within(target, destination):
                raise ValueError(f"Archive entry escapes its destination: {info.filename}.")
            # Case-fold on every platform so an extraction prepared on macOS is
            # guaranteed to remain representable if copied to Windows.
            collision_key = str(target).casefold()
            if collision_key in owners and owners[collision_key] != info.filename:
                if collision_policy != "rename":
                    raise ValueError(f"Distinct archive paths map to the same path: {owners[collision_key]} and {info.filename}.")
                original_target = target
                marker = f"__case_collision_{info.CRC:08x}"
                target = target.with_name(f"{target.stem}{marker}{target.suffix}")
                collision_key = str(target).casefold()
                counter = 2
                while collision_key in owners:
                    target = original_target.with_name(f"{original_target.stem}{marker}_{counter}{original_target.suffix}")
                    collision_key = str(target).casefold()
                    counter += 1
                collisions.append({"ArchivePath": info.filename, "ExtractedPath": target.relative_to(destination.resolve()).as_posix()})
            owners[collision_key] = info.filename
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
    return collisions


def compress_directory(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source).as_posix())
