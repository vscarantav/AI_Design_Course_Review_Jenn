from __future__ import annotations

import csv
import io
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

from .archive import compress_directory, expand_safe_archive
from .common import local_name, relative_unix, safe_slug, sha256, write_json

REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


def _register_namespaces(source) -> None:
    for _event, (prefix, uri) in ET.iterparse(source, events=("start-ns",)):
        if prefix == "xml" or re.match(r"ns\d+$", prefix or ""):
            continue
        try:
            ET.register_namespace(prefix or "", uri)
        except ValueError:
            pass


def _reject_dtd(data: bytes) -> None:
    upper = data.upper()
    if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
        raise ValueError("DTD and entity declarations are not allowed in XML evidence.")


def parse_xml_bytes(data: bytes) -> ET.ElementTree:
    _reject_dtd(data)
    _register_namespaces(io.BytesIO(data))
    return ET.ElementTree(ET.fromstring(data))


def parse_xml(path: Path) -> ET.ElementTree:
    data = path.read_bytes()
    return parse_xml_bytes(data)


def _sheet_records(package_root: Path):
    workbook_path = package_root / "xl" / "workbook.xml"
    rels_path = package_root / "xl" / "_rels" / "workbook.xml.rels"
    if not workbook_path.exists() or not rels_path.exists():
        return []
    rels = {
        node.attrib.get("Id"): node.attrib.get("Target", "")
        for node in parse_xml(rels_path).getroot().iter()
        if local_name(node.tag) == "Relationship"
    }
    result = []
    for sheet in parse_xml(workbook_path).getroot().iter():
        if local_name(sheet.tag) != "sheet":
            continue
        relationship_id = sheet.attrib.get(f"{{{REL_NS}}}id")
        target = rels.get(relationship_id, "").replace("\\", "/")
        while target.startswith("../"):
            target = target[3:]
        path = (package_root / "xl" / Path(*target.split("/"))).resolve()
        if path.is_relative_to(package_root.resolve()) and path.exists():
            result.append((sheet.attrib.get("name", ""), sheet.attrib.get("state", "visible"), path))
    return result


def _shared_strings(package_root: Path) -> list[str]:
    path = package_root / "xl" / "sharedStrings.xml"
    if not path.exists():
        return []
    strings = []
    for node in parse_xml(path).getroot().iter():
        if local_name(node.tag) == "si":
            strings.append("".join(n.text or "" for n in node.iter() if local_name(n.tag) == "t"))
    return strings


def _cell_value(cell: ET.Element, shared: list[str]) -> tuple[str, str]:
    cell_type = cell.attrib.get("t", "n")
    raw = ""
    formula = ""
    for node in list(cell):
        name = local_name(node.tag)
        if name == "v":
            raw = node.text or ""
        elif name == "f":
            formula = node.text or ""
        elif name == "is":
            raw = "".join(n.text or "" for n in node.iter() if local_name(n.tag) == "t")
    if cell_type == "s":
        try:
            raw = shared[int(raw)]
        except (ValueError, IndexError):
            pass
    return formula, raw


def write_normalized_workbook(package_root: Path, output: Path) -> None:
    root = ET.Element("Workbook")
    shared = _shared_strings(package_root)
    for name, state, path in _sheet_records(package_root):
        sheet_out = ET.SubElement(root, "Sheet", {"name": name, "state": state})
        for cell in parse_xml(path).getroot().iter():
            if local_name(cell.tag) != "c":
                continue
            formula, value = _cell_value(cell, shared)
            cell_out = ET.SubElement(sheet_out, "Cell", {"ref": cell.attrib.get("r", ""), "type": cell.attrib.get("t", "n")})
            if formula:
                ET.SubElement(cell_out, "Formula").text = formula
            ET.SubElement(cell_out, "Value").text = value
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def write_normalized_document(package_root: Path, output: Path) -> None:
    root = ET.Element("Document")
    source = package_root / "word" / "document.xml"
    index = 0
    if source.exists():
        for paragraph in parse_xml(source).getroot().iter():
            if local_name(paragraph.tag) != "p":
                continue
            text = "".join(n.text or "" for n in paragraph.iter() if local_name(n.tag) == "t")
            if text.strip():
                index += 1
                ET.SubElement(root, "Paragraph", {"index": str(index)}).text = text
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def _review_views(artifact_root: Path, normalized: Path, extension: str, run_path: Path) -> list[str]:
    views = artifact_root / "views"
    views.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    index: list[dict] = []
    root = parse_xml(normalized).getroot()
    if extension == ".xlsx":
        used: set[str] = set()
        for sheet in root.findall("Sheet"):
            state = sheet.attrib.get("state", "visible")
            if state != "visible":
                continue
            base = safe_slug(sheet.attrib.get("name", "sheet"), 48)
            name = f"{base}.tsv"
            suffix = 2
            while name in used:
                name = f"{base}-{suffix}.tsv"
                suffix += 1
            used.add(name)
            path = views / name
            with path.open("w", encoding="utf-8-sig", newline="") as stream:
                writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
                writer.writerow(["Cell", "Formula", "Value"])
                for cell in sheet.findall("Cell"):
                    writer.writerow([cell.attrib.get("ref", ""), cell.findtext("Formula", ""), cell.findtext("Value", "")])
            relative = relative_unix(run_path, path)
            files.append(relative)
            index.append({"Sheet": sheet.attrib.get("name", ""), "State": state, "CellCount": len(sheet.findall("Cell")), "File": relative})
    else:
        path = views / "document.txt"
        paragraphs = [node.text or "" for node in root.findall("Paragraph")]
        path.write_text("\n".join(paragraphs) + ("\n" if paragraphs else ""), encoding="utf-8-sig")
        relative = relative_unix(run_path, path)
        files.append(relative)
        index.append({"Document": "document", "ParagraphCount": len(paragraphs), "File": relative})
    write_json(index, artifact_root / "review_index.json")
    return files


def expand_office_document(source: Path, run_path: Path, office_root: Path) -> dict:
    digest = sha256(source)
    artifact_id = f"{safe_slug(source.stem, 42)}-{digest[:10]}"
    artifact_root = office_root / artifact_id
    package_root = artifact_root / "package"
    artifact_root.mkdir(parents=True, exist_ok=True)
    expand_safe_archive(source, package_root)
    normalized = artifact_root / "normalized.xml"
    extension = source.suffix.lower()
    if extension == ".xlsx":
        write_normalized_workbook(package_root, normalized)
    elif extension == ".docx":
        write_normalized_document(package_root, normalized)
    else:
        raise ValueError(f"Unsupported Office document: {source}")
    artifact = {
        "Id": artifact_id,
        "SourcePath": str(source.resolve()),
        "SourceRelativePath": relative_unix(run_path, source) if source.resolve().is_relative_to(run_path.resolve()) else source.name,
        "FileName": source.name,
        "Kind": extension.lstrip("."),
        "Sha256": digest,
        "PackageDirectory": relative_unix(run_path, package_root),
        "NormalizedXml": relative_unix(run_path, normalized),
        "ReviewFiles": _review_views(artifact_root, normalized, extension, run_path),
        "PackageEntryCount": sum(1 for path in package_root.rglob("*") if path.is_file()),
    }
    write_json(artifact, artifact_root / "document.json")
    return artifact


def restore_office_document(artifact: dict, run_path: Path) -> Path:
    package_root = run_path / artifact["PackageDirectory"]
    if not (package_root / "[Content_Types].xml").exists():
        raise ValueError(f"OOXML package is incomplete for {artifact['FileName']}.")
    output = run_path / "output" / "rebuilt_office" / artifact["FileName"]
    compress_directory(package_root, output)
    with zipfile.ZipFile(output) as archive:
        if "[Content_Types].xml" not in archive.namelist():
            raise ValueError(f"Rebuilt Office package failed validation: {output}")
    return output


def workbook_sheet_path(package_root: Path, sheet_name: str) -> Path:
    for name, _state, path in _sheet_records(package_root):
        if name == sheet_name:
            return path
    raise ValueError(f"Workbook sheet not found: {sheet_name}")
