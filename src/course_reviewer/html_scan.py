from __future__ import annotations

import html
import re
from pathlib import Path

from .common import relative_unix, safe_slug, write_json


def html_to_text(value: str | None) -> str:
    if value is None:
        return ""
    value = re.sub(r"<script\b.*?</script>|<style\b.*?</style>", " ", value, flags=re.I | re.S)
    value = re.sub(r"</(?:p|div|li|h[1-6]|tr|section|article)>|<br\s*/?>", "\n", value, flags=re.I)
    value = re.sub(r"<[^>]+>", " ", value, flags=re.S)
    value = html.unescape(value)
    value = re.sub(r"[ \t]+", " ", value)
    value = re.sub(r"(?:\r?\n\s*){3,}", "\n\n", value)
    return value.strip()


def scan_html(extracted_root: Path, evidence_root: Path) -> list[dict]:
    results = []
    text_root = evidence_root / "text"
    text_root.mkdir(parents=True, exist_ok=True)
    used: set[str] = set()
    for path in sorted([*extracted_root.rglob("*.html"), *extracted_root.rglob("*.htm")]):
        source = path.read_text(encoding="utf-8", errors="replace")
        relative = relative_unix(extracted_root, path)
        text = html_to_text(source)
        base = safe_slug(path.stem, 45)
        name = f"{base}.txt"
        suffix = 2
        while name in used:
            name = f"{base}-{suffix}.txt"
            suffix += 1
        used.add(name)
        text_path = text_root / name
        text_path.write_text(f"SOURCE: {relative}\n\n{text}", encoding="utf-8")
        images = re.findall(r"<img\b[^>]*>", source, flags=re.I)
        missing_alt = sum(1 for tag in images if not re.search(r"\balt\s*=", tag, re.I) or re.search(r'''\balt\s*=\s*(["'])(?:\s*|[^"']*\.(?:png|jpe?g|gif|svg))\1''', tag, re.I))
        heading_levels = [int(v) for v in re.findall(r"<h([1-6])\b", source, flags=re.I)]
        heading_issues = sum(1 for a, b in zip(heading_levels, heading_levels[1:]) if b > a + 1)
        tables = re.findall(r"<table\b.*?</table>", source, flags=re.I | re.S)
        tables_without_headers = sum(1 for table in tables if not re.search(r"<th\b", table, re.I))
        links = re.findall(r"<a\b[^>]*>(.*?)</a>", source, flags=re.I | re.S)
        vague_links = sum(1 for link in links if re.match(r"^(click here|here|link|read more|more)$", html_to_text(link), re.I))
        urls = sorted(set(value.rstrip(".,)]\"'") for value in re.findall(r'''https?://[^\s<>"']+''', html.unescape(source), flags=re.I)))
        internal_refs = sorted(set(re.findall(r'''(?:\$IMS-CC-FILEBASE\$|\$CANVAS_OBJECT_REFERENCE\$|\$WIKI_REFERENCE\$)[^"'<>\s]*''', source, flags=re.I)))
        words = re.findall(r"\b[^\W_][\w'-]*\b", text, flags=re.UNICODE)
        sentences = [v for v in re.findall(r"[^.!?]+[.!?]+|[^.!?]+$", text) if re.search(r"\w", v)]
        long_sentences = sum(1 for sentence in sentences if len(re.findall(r"\b\w+\b", sentence)) > 25)
        syllables = 0
        for word in re.findall(r"\b[a-z]+\b", text.lower()):
            count = len(re.findall(r"[aeiouy]+", word))
            if word.endswith("e") and count > 1:
                count -= 1
            syllables += max(1, count)
        grade = round(0.39 * (len(words) / len(sentences)) + 11.8 * (syllables / len(words)) - 15.59, 1) if words and sentences else None
        inline_colors = len(re.findall(r"(?:color|background-color)\s*:", source, flags=re.I))
        issues = []
        for count, message in (
            (missing_alt, "image(s) have missing or unhelpful alt text."),
            (heading_issues, "heading-level jump(s) detected."),
            (tables_without_headers, "table(s) contain no header cells."),
            (vague_links, "link(s) use vague text such as 'click here'."),
            (inline_colors, "inline color declaration(s) require contrast/manual review."),
        ):
            if count:
                issues.append(f"{count} {message}")
        results.append({
            "Path": relative, "WordCount": len(words), "ImageCount": len(images), "MissingAltCount": missing_alt,
            "HeadingCount": len(heading_levels), "HeadingOrderIssueCount": heading_issues, "TableCount": len(tables),
            "TableWithoutHeaderCount": tables_without_headers, "VagueLinkCount": vague_links, "InlineColorCount": inline_colors,
            "LongSentenceCount": long_sentences, "FleschKincaidGrade": grade, "ExternalUrls": urls,
            "InternalReferences": internal_refs, "Issues": issues, "TextFile": relative_unix(evidence_root, text_path),
        })
    write_json(results, evidence_root / "html_analysis.json")
    return results
