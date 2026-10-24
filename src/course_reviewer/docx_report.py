from __future__ import annotations

import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from .common import read_json

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
CP = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
DC = "http://purl.org/dc/elements/1.1/"
DCTERMS = "http://purl.org/dc/terms/"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
ET.register_namespace("w", W)
ET.register_namespace("r", R)


def _q(namespace: str, name: str) -> str:
    return f"{{{namespace}}}{name}"


def _paragraph(parent: ET.Element, text: str = "", style: str | None = None, *, keep_next: bool = False, bold: bool = False) -> ET.Element:
    paragraph = ET.SubElement(parent, _q(W, "p"))
    properties = ET.SubElement(paragraph, _q(W, "pPr"))
    if style:
        ET.SubElement(properties, _q(W, "pStyle"), {_q(W, "val"): style})
    if keep_next:
        ET.SubElement(properties, _q(W, "keepNext"))
    if text:
        run = ET.SubElement(paragraph, _q(W, "r"))
        if bold:
            run_properties = ET.SubElement(run, _q(W, "rPr"))
            ET.SubElement(run_properties, _q(W, "b"))
        node = ET.SubElement(run, _q(W, "t"))
        if text[:1].isspace() or text[-1:].isspace():
            node.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        node.text = text
    return paragraph


def _labelled_list(body: ET.Element, label: str, values: list) -> None:
    _paragraph(body, label, "Heading3", keep_next=True)
    if not values:
        _paragraph(body, "None", "ListBullet")
        return
    for value in values:
        _paragraph(body, f"- {value}", "ListBullet")


def _table_cell(row: ET.Element, text: str, *, header: bool = False, fill: str | None = None, width: int = 3000, center: bool = False) -> None:
    cell = ET.SubElement(row, _q(W, "tc"))
    cell_properties = ET.SubElement(cell, _q(W, "tcPr"))
    ET.SubElement(cell_properties, _q(W, "tcW"), {_q(W, "w"): str(width), _q(W, "type"): "dxa"})
    ET.SubElement(cell_properties, _q(W, "vAlign"), {_q(W, "val"): "center"})
    if header or fill:
        ET.SubElement(cell_properties, _q(W, "shd"), {_q(W, "fill"): "1F4E78" if header else fill})
    margins = ET.SubElement(cell_properties, _q(W, "tcMar"))
    for side in ("top", "left", "bottom", "right"):
        ET.SubElement(margins, _q(W, side), {_q(W, "w"): "100", _q(W, "type"): "dxa"})
    paragraph = _paragraph(cell, text)
    if center:
        paragraph_properties = next(node for node in paragraph if node.tag == _q(W, "pPr"))
        ET.SubElement(paragraph_properties, _q(W, "jc"), {_q(W, "val"): "center"})
    if header:
        run = next((node for node in paragraph if node.tag == _q(W, "r")), None)
        if run is not None:
            props = ET.Element(_q(W, "rPr"))
            ET.SubElement(props, _q(W, "b"))
            ET.SubElement(props, _q(W, "color"), {_q(W, "val"): "FFFFFF"})
            run.insert(0, props)


def _status_table(body: ET.Element, findings: list[dict]) -> None:
    counts = Counter(pair["Finding"]["Status"] for pair in findings)
    table = ET.SubElement(body, _q(W, "tbl"))
    properties = ET.SubElement(table, _q(W, "tblPr"))
    ET.SubElement(properties, _q(W, "tblW"), {_q(W, "w"): "6000", _q(W, "type"): "dxa"})
    borders = ET.SubElement(properties, _q(W, "tblBorders"))
    for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
        ET.SubElement(borders, _q(W, side), {_q(W, "val"): "single", _q(W, "sz"): "4", _q(W, "color"): "D9D9D9"})
    header = ET.SubElement(table, _q(W, "tr"))
    _table_cell(header, "Status", header=True, width=4500); _table_cell(header, "Count", header=True, width=1500, center=True)
    for index, status in enumerate(("Verified", "In Progress", "Needs Attention", "Exempt", "Unable to Verify")):
        row = ET.SubElement(table, _q(W, "tr"))
        fill = "DDEBF7" if index % 2 else None
        _table_cell(row, status, fill=fill, width=4500); _table_cell(row, str(counts.get(status, 0)), fill=fill, width=1500, center=True)


def _document_xml(run_path: Path, run: dict, validation: dict) -> bytes:
    summary = read_json(run_path / "evidence" / "course_summary.json")
    document = ET.Element(_q(W, "document"))
    body = ET.SubElement(document, _q(W, "body"))
    display = summary.get("CourseCode") or summary.get("Title") or Path(run["SourcePackage"]).stem
    _paragraph(body, f"Course Review {display}", "Title")
    _paragraph(body, "This report records the completed evidence based course design review. It summarizes review status, cited evidence, identified issues, recommended actions, and any information still needed from the requester.")
    _paragraph(body, "Review Overview", "Heading1", keep_next=True)
    overview = [
        f"Course title: {summary.get('Title') or ''}", f"Course code: {summary.get('CourseCode') or ''}",
        f"Source package: {Path(run['SourcePackage']).name}", f"Course workbook: {Path(run['SourceWorkbook']).name}",
        f"Modules: {summary.get('ModuleCount', 0)}", f"Items: {summary.get('ItemCount', 0)}",
        f"Published items: {summary.get('PublishedItemCount', 0)}", f"Review generated: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %z')}",
    ]
    for value in overview:
        _paragraph(body, f"- {value}", "ListBullet")
    _paragraph(body, "Status Summary", "Heading1", keep_next=True)
    _status_table(body, validation["Findings"])
    current_category = None
    for pair in validation["Findings"]:
        criterion, finding = pair["Criterion"], pair["Finding"]
        if criterion["Category"] != current_category:
            current_category = criterion["Category"]
            category_heading = current_category.replace(" — ", " ")
            _paragraph(body, category_heading, "Heading1", keep_next=True)
        suffix = []
        if criterion["Required"]: suffix.append("Required")
        if criterion["Wwo"]: suffix.append("WWO")
        heading = f"{criterion['Id']} {criterion['Title']}"
        if suffix: heading += f" ({', '.join(suffix)})"
        _paragraph(body, heading, "Heading2", keep_next=True)
        _paragraph(body, f"Status: {finding['Status']}   Confidence: {finding['Confidence']}", bold=True)
        _labelled_list(body, "Evidence", finding["Evidence"])
        _labelled_list(body, "Issues", finding["Issues"])
        _labelled_list(body, "Recommendations", finding["Recommendations"])
        _labelled_list(body, "Needs from requester", finding["NeedsFromRequester"])
    for name, title in (("contradictions.md", "Contradictions"), ("not_reviewed.md", "Content Not Reviewed"), ("settings_and_assumptions.md", "Settings and Assumptions"), ("prior_review_comparison.md", "Prior Review Comparison")):
        path = run_path / "findings" / name
        if not path.exists(): continue
        _paragraph(body, title, "Heading1", keep_next=True)
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            clean = line.strip().lstrip("#").strip()
            if clean: _paragraph(body, clean, "ListBullet" if clean.startswith("-") else None)
    section = ET.SubElement(body, _q(W, "sectPr"))
    ET.SubElement(section, _q(W, "pgSz"), {_q(W, "w"): "12240", _q(W, "h"): "15840"})
    ET.SubElement(section, _q(W, "pgMar"), {_q(W, "top"): "1080", _q(W, "right"): "1080", _q(W, "bottom"): "1080", _q(W, "left"): "1080", _q(W, "header"): "720", _q(W, "footer"): "720", _q(W, "gutter"): "0"})
    return ET.tostring(document, encoding="utf-8", xml_declaration=True)


def _styles_xml() -> bytes:
    styles = ET.Element(_q(W, "styles"))
    defaults = ET.SubElement(styles, _q(W, "docDefaults"))
    run_default = ET.SubElement(ET.SubElement(defaults, _q(W, "rPrDefault")), _q(W, "rPr"))
    ET.SubElement(run_default, _q(W, "rFonts"), {_q(W, "ascii"): "Arial", _q(W, "hAnsi"): "Arial"})
    ET.SubElement(run_default, _q(W, "sz"), {_q(W, "val"): "22"})
    paragraph_default = ET.SubElement(ET.SubElement(defaults, _q(W, "pPrDefault")), _q(W, "pPr"))
    ET.SubElement(paragraph_default, _q(W, "spacing"), {_q(W, "after"): "120", _q(W, "line"): "276", _q(W, "lineRule"): "auto"})
    def style(style_id: str, name: str, size: int, *, bold=False, before=0, after=120, left=0, hanging=0):
        node = ET.SubElement(styles, _q(W, "style"), {_q(W, "type"): "paragraph", _q(W, "styleId"): style_id})
        ET.SubElement(node, _q(W, "name"), {_q(W, "val"): name})
        props = ET.SubElement(node, _q(W, "pPr")); ET.SubElement(props, _q(W, "spacing"), {_q(W, "before"): str(before), _q(W, "after"): str(after)})
        if left: ET.SubElement(props, _q(W, "ind"), {_q(W, "left"): str(left), _q(W, "hanging"): str(hanging)})
        run = ET.SubElement(node, _q(W, "rPr")); ET.SubElement(run, _q(W, "color"), {_q(W, "val"): "000000"}); ET.SubElement(run, _q(W, "sz"), {_q(W, "val"): str(size)})
        if bold: ET.SubElement(run, _q(W, "b"))
    style("Normal", "Normal", 22)
    style("Title", "Title", 36, bold=True, after=260)
    style("Heading1", "heading 1", 28, bold=True, before=300, after=120)
    style("Heading2", "heading 2", 24, bold=True, before=220, after=80)
    style("Heading3", "heading 3", 22, bold=True, before=120, after=40)
    style("ListBullet", "List Bullet", 22, after=60, left=480, hanging=240)
    return ET.tostring(styles, encoding="utf-8", xml_declaration=True)


def write_docx_report(run_path: Path, run: dict, validation: dict) -> Path:
    output = run_path / "output" / "course_review.docx"
    output.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    parts = {
        "[Content_Types].xml": b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>''',
        "_rels/.rels": b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>''',
        "word/_rels/document.xml.rels": b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''',
        "word/document.xml": _document_xml(run_path, run, validation),
        "word/styles.xml": _styles_xml(),
        "docProps/core.xml": f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="{CP}" xmlns:dc="{DC}" xmlns:dcterms="{DCTERMS}" xmlns:xsi="{XSI}"><dc:title>Course Review</dc:title><dc:creator>IMSCC Course Reviewer</dc:creator><cp:lastModifiedBy>IMSCC Course Reviewer</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">{now}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">{now}</dcterms:modified></cp:coreProperties>'''.encode(),
        "docProps/app.xml": b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>IMSCC Course Reviewer</Application></Properties>''',
    }
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items(): archive.writestr(name, data)
    return output
