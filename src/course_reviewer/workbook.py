from __future__ import annotations

import re
from pathlib import Path
from xml.etree import ElementTree as ET

from .common import finding_filename, normalized_key, read_json, relative_unix, write_json
from .office import parse_xml, workbook_sheet_path
from .packets import criterion_definitions

SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
XML_NS = "http://www.w3.org/XML/1998/namespace"
ET.register_namespace("", SHEET_NS)


def resolve_course_workbook(root: Path, course: dict, workbook_path: str | None = None) -> Path:
    if workbook_path:
        candidate = Path(workbook_path)
        if not candidate.is_absolute():
            candidate = root / candidate
        candidate = candidate.resolve()
        if not candidate.exists():
            raise ValueError(f"Course workbook not found: {candidate}")
        if candidate.suffix.lower() != ".xlsx":
            raise ValueError(f"Course workbook must be an .xlsx file: {candidate}")
        return candidate
    directory = Path(course["Path"]).parent
    candidates = sorted(directory.glob("*.xlsx"))
    if not candidates:
        raise ValueError(f"No course workbook was found beside {course['FileName']}. Place the course .xlsx workbook in {directory}.")
    if len(candidates) == 1:
        return candidates[0].resolve()
    package_key = normalized_key(Path(course["FileName"]).stem)
    code_match = re.search(r"\b[A-Z]{2,}\s*[- ]?\s*\d+[A-Z]?\b", course.get("CourseCode") or "", re.I)
    code_key = normalized_key(code_match.group()) if code_match else ""
    ranked = []
    for path in candidates:
        key = normalized_key(path.stem)
        score = 100 if key == package_key else (70 if package_key and package_key in key else 0)
        if code_key and code_key in key:
            score += 60
        if "courseworkbook" in key:
            score += 20
        ranked.append((score, path))
    best_score = max(score for score, _ in ranked)
    best = [path for score, path in ranked if score == best_score]
    if best_score > 0 and len(best) == 1:
        return best[0].resolve()
    raise ValueError(f"The course workbook is ambiguous for {course['FileName']}. Use --workbook with one of: {', '.join(p.name for p in candidates)}")


def write_design_review_contract(artifact: dict, run_path: Path, baseline_path: Path) -> dict:
    if artifact["Kind"] != "xlsx":
        raise ValueError("The course workbook artifact must be an XLSX document.")
    root = parse_xml(run_path / artifact["NormalizedXml"]).getroot()
    sheet = next((node for node in root.findall("Sheet") if node.attrib.get("name", "").lower() == "design review"), None)
    if sheet is None:
        raise ValueError(f"The required 'Design Review' tab was not found in {artifact['FileName']}.")
    cells = {cell.attrib.get("ref", ""): cell.findtext("Value", "") for cell in sheet.findall("Cell")}
    header_row = 0
    status_column = ""
    for reference, value in cells.items():
        match = re.match(r"^([A-Z]+)(\d+)$", reference)
        if value == "Status" and match:
            status_column, header_row = match.group(1), int(match.group(2))
    if not header_row or not status_column:
        raise ValueError("The 'Design Review' tab has no recognizable Status header.")
    reviewer_columns = []
    for reference, value in cells.items():
        match = re.match(r"^([A-Z]+)(\d+)$", reference)
        if match and int(match.group(2)) == header_row and value.startswith("Reviewer Notes"):
            reviewer_columns.append(match.group(1))
    definitions = criterion_definitions(baseline_path.read_text(encoding="utf-8-sig"))
    by_id = {item["Id"]: item for item in definitions}
    mapped = []
    for reference, value in cells.items():
        match = re.match(r"^A(\d+)$", reference)
        if not match or int(match.group(1)) <= header_row:
            continue
        row = int(match.group(1))
        raw = (value or "").strip().rstrip("*")
        if not re.match(r"^\d+\.\d+$", raw):
            continue
        criterion_id = raw
        if criterion_id not in by_id and re.match(r"^\d+\.\d$", raw) and raw + "0" in by_id:
            criterion_id = raw + "0"
        if criterion_id not in by_id:
            continue
        notes = [{"Cell": f"{col}{row}", "Header": cells.get(f"{col}{header_row}", ""), "Value": cells.get(f"{col}{row}", "")} for col in reviewer_columns]
        mapped.append({
            "Id": criterion_id, "Required": bool(by_id[criterion_id]["Required"]), "Row": row,
            "MetricCell": f"A{row}", "CriteriaCell": f"B{row}", "Criteria": cells.get(f"B{row}", ""),
            "StatusCell": f"{status_column}{row}", "ExistingStatus": cells.get(f"{status_column}{row}", ""),
            "ExistingReviewerNotes": notes,
        })
    mapped.sort(key=lambda item: item["Row"])
    mapped_ids = {item["Id"] for item in mapped}
    contract = {
        "Workbook": artifact["FileName"], "WorkbookSha256": artifact["Sha256"], "Sheet": "Design Review",
        "HeaderRow": header_row, "StatusColumn": status_column, "ExistingReviewerNoteColumns": reviewer_columns,
        "AutomatedReviewerNotesColumn": "J", "AutomatedReviewerNotesHeader": "Automated Reviewer Notes",
        "AllowedWorkbookStatuses": ["Verified", "In Progress", "Needs Attention", "Exempt"],
        "StatusValidationPolicy": "Normalize list validation on Design Review status cells to the four institutional statuses stated in the sheet instructions.",
        "UnableToVerifyPolicy": "Leave the workbook Status cell unchanged and record Unable to Verify in Automated Reviewer Notes and the Markdown audit.",
        "CheckColumnPolicy": "Preserve existing Check cells and formulas; they are a separate human/legacy workflow.",
        "Criteria": mapped,
        "MissingBaselineCriteria": [item["Id"] for item in definitions if item["Id"] not in mapped_ids],
    }
    path = run_path / "evidence" / "design_review_contract.json"
    write_json(contract, path)
    return {"Path": relative_unix(run_path, path), "Contract": contract}


def _find(root: ET.Element, local: str, **attrs) -> ET.Element | None:
    for node in root.iter():
        if local_name(node.tag) == local and all(node.attrib.get(k) == v for k, v in attrs.items()):
            return node
    return None


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _column_number(name: str) -> int:
    value = 0
    for char in name.upper():
        value = value * 26 + ord(char) - ord("A") + 1
    return value


def _style(root: ET.Element, reference: str) -> str:
    cell = _find(root, "c", r=reference)
    return cell.attrib.get("s", "") if cell is not None else ""


def _set_inline(root: ET.Element, reference: str, value: str, style: str = "") -> None:
    match = re.match(r"^([A-Z]+)(\d+)$", reference)
    if not match:
        raise ValueError(f"Invalid cell reference: {reference}")
    column, row_number = match.group(1), match.group(2)
    sheet_data = _find(root, "sheetData")
    row = next((n for n in list(sheet_data) if local_name(n.tag) == "row" and n.attrib.get("r") == row_number), None) if sheet_data is not None else None
    if row is None:
        raise ValueError(f"Worksheet row not found for {reference}")
    cell = next((n for n in list(row) if local_name(n.tag) == "c" and n.attrib.get("r") == reference), None)
    if cell is None:
        cell = ET.Element(f"{{{SHEET_NS}}}c", {"r": reference})
        index = _column_number(column)
        inserted = False
        for position, existing in enumerate(list(row)):
            existing_match = re.match(r"^([A-Z]+)\d+$", existing.attrib.get("r", ""))
            if existing_match and _column_number(existing_match.group(1)) > index:
                row.insert(position, cell)
                inserted = True
                break
        if not inserted:
            row.append(cell)
    if style:
        cell.attrib["s"] = style
    cell.attrib["t"] = "inlineStr"
    for child in list(cell):
        cell.remove(child)
    inline = ET.SubElement(cell, f"{{{SHEET_NS}}}is")
    text = ET.SubElement(inline, f"{{{SHEET_NS}}}t")
    text.attrib[f"{{{XML_NS}}}space"] = "preserve"
    text.text = value


def _review_note(finding: dict) -> str:
    status = finding.get("status", finding.get("Status", ""))
    parts = [f"Automated review: {status}."]
    for label, names in (
        ("Evidence", ("evidence", "Evidence")), ("Issues", ("issues", "Issues")),
        ("Recommendations", ("recommendations", "Recommendations")),
        ("Needs from requester", ("needs_from_requester", "NeedsFromRequester")),
    ):
        values = next((finding[name] for name in names if name in finding), []) or []
        values = [str(value) for value in values if str(value).strip()]
        if values:
            parts.append(f"{label}: {' | '.join(values)}")
    return "\n".join(parts)


def update_design_review_workbook(artifact: dict, run_path: Path, contract: dict) -> dict:
    package_root = run_path / artifact["PackageDirectory"]
    sheet_path = workbook_sheet_path(package_root, contract["Sheet"])
    original_xml = sheet_path.read_bytes()
    tree = parse_xml(sheet_path)
    root = tree.getroot()
    for validation in root.iter():
        if local_name(validation.tag) != "dataValidation" or validation.attrib.get("type") != "list":
            continue
        if re.search(rf"(^|\s){re.escape(contract['StatusColumn'])}\d+", validation.attrib.get("sqref", "")):
            formula = next((n for n in list(validation) if local_name(n.tag) == "formula1"), None)
            if formula is not None:
                formula.text = '"Needs Attention,In Progress,Verified,Exempt"'
    header_ref = f"{contract['AutomatedReviewerNotesColumn']}{contract['HeaderRow']}"
    _set_inline(root, header_ref, contract["AutomatedReviewerNotesHeader"], _style(root, f"G{contract['HeaderRow']}"))
    updated = []
    for criterion in contract["Criteria"]:
        path = run_path / "findings" / finding_filename(criterion["Id"])
        if not path.exists():
            continue
        finding = read_json(path)
        status = finding.get("status", finding.get("Status", ""))
        if status in contract["AllowedWorkbookStatuses"]:
            _set_inline(root, criterion["StatusCell"], status, _style(root, criterion["StatusCell"]))
        note_ref = f"{contract['AutomatedReviewerNotesColumn']}{criterion['Row']}"
        _set_inline(root, note_ref, _review_note(finding), _style(root, f"G{criterion['Row']}"))
        updated.append(criterion["Id"])
    serialized = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    original_root = re.search(rb"<([A-Za-z_][\w.-]*:)?worksheet\b([^>]*)>", original_xml)
    declarations = re.findall(rb"\s(xmlns(?::[A-Za-z_][\w.-]*)?\s*=\s*['\"][^'\"]+['\"])", original_root.group(2) if original_root else b"")
    root_match = re.search(rb"<([A-Za-z_][\w.-]*:)?worksheet\b", serialized)
    if root_match:
        insertion = root_match.end()
        end = serialized.find(b">", insertion)
        present = {match.group(1).split(b"=", 1)[0].strip() for match in re.finditer(rb"\s(xmlns(?::[A-Za-z_][\w.-]*)?\s*=)", serialized[insertion:end])}
        missing = [b" " + value for value in declarations if value.split(b"=", 1)[0].strip() not in present]
        serialized = serialized[:insertion] + b"".join(missing) + serialized[insertion:]
    sheet_path.write_bytes(serialized)
    return {
        "Workbook": artifact["FileName"], "Sheet": contract["Sheet"], "UpdatedCriteria": updated,
        "UnmappedCriteria": list(contract["MissingBaselineCriteria"]), "AutomatedNotesColumn": contract["AutomatedReviewerNotesColumn"],
    }
