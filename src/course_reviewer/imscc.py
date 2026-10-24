from __future__ import annotations

import html
import re
import urllib.parse
import zipfile
from collections import Counter
from pathlib import Path
from xml.etree import ElementTree as ET

from .archive import safe_archive_relative_path
from .common import child_text, local_name, relative_unix, safe_slug, write_json
from .html_scan import html_to_text
from .office import parse_xml, parse_xml_bytes


def _nodes(root: ET.Element, name: str):
    return [node for node in root.iter() if local_name(node.tag) == name]


def course_identity(package: Path) -> dict:
    try:
        with zipfile.ZipFile(package) as archive:
            info = archive.getinfo("course_settings/course_settings.xml")
            if info.file_size > 10_000_000:
                return {"Title": None, "CourseCode": None}
            root = parse_xml_bytes(archive.read(info)).getroot()
        return {"Title": child_text(root, "title"), "CourseCode": child_text(root, "course_code")}
    except Exception:
        return {"Title": None, "CourseCode": None}


def _resolve_package_path(root: Path, relative: str) -> Path:
    decoded = urllib.parse.unquote(re.split(r"[?#]", relative or "")[0]).lstrip("/\\")
    target = (root / safe_archive_relative_path(decoded)).resolve()
    try:
        target.relative_to(root.resolve())
        return target
    except ValueError:
        return root / "__invalid_reference__"


def _week_number(value: str) -> str | None:
    match = re.search(r"(?:week|w)\s*0?(\d{1,2})", value or "", re.I)
    return f"{int(match.group(1)):02d}" if match else None


def _instructor_facing(value: str) -> bool:
    return bool(re.search(r"instructor|teaching notes|setup notes|grader|do not publish|course resources", value or "", re.I))


def _add_item_details(item: dict, resource: dict | None, extracted_root: Path) -> None:
    if not resource:
        return
    candidates: list[Path] = []
    for relative in sorted(set(filter(None, [resource.get("Href"), *resource.get("Files", [])]))):
        path = _resolve_package_path(extracted_root, relative)
        if path not in candidates:
            candidates.append(path)
        if path.exists() and path.parent != extracted_root.resolve():
            candidates.extend(sibling for sibling in path.parent.iterdir() if sibling.is_file() and sibling not in candidates)
    if "Discussion" in (item.get("Type") or ""):
        topic_ids = {str(item["IdentifierRef"])} if item.get("IdentifierRef") else set()
        for path in list(candidates):
            if not path.exists() or path.suffix.lower() != ".xml":
                continue
            try:
                topic_ids.update("".join(node.itertext()).strip() for node in _nodes(parse_xml(path).getroot(), "topic_id") if "".join(node.itertext()).strip())
            except Exception:
                pass
        for root_xml in extracted_root.glob("*.xml"):
            if root_xml in candidates:
                continue
            try:
                raw = root_xml.read_text(encoding="utf-8", errors="replace")
                if any(f"<{topic_id}" in raw or f">{topic_id}<" in raw for topic_id in topic_ids):
                    candidates.append(root_xml)
            except OSError:
                pass
    setting_names = {
        "points_possible", "grading_type", "submission_types", "allowed_extensions", "allowed_attempts", "due_at",
        "lock_at", "unlock_at", "quiz_type", "group_category_id", "workflow_state", "assignment_group_identifier_ref",
        "rubric_identifierref", "rubric_use_for_grading", "show_correct_answers", "hide_correct_answers_at",
    }
    urls, question_types = set(), set()
    for path in candidates:
        if not path.exists() or path.stat().st_size > 50_000_000:
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
            urls.update(value.rstrip(".,)]\"'") for value in re.findall(r'''https?://[^\s<>"']+''', html.unescape(content), re.I))
            if path.suffix.lower() not in {".xml", ".qti"}:
                continue
            root = parse_xml(path).getroot()
            for node in root.iter():
                name = local_name(node.tag)
                text = "".join(node.itertext()).strip()
                if name in setting_names and text and name not in item["Settings"]:
                    item["Settings"][name] = text
                if name == "question_type" and text:
                    question_types.add(text)
            for label in _nodes(root, "fieldlabel"):
                if (label.text or "").strip() == "question_type":
                    parent = next((p for p in root.iter() if label in list(p)), None)
                    if parent is not None:
                        value = next(("".join(n.itertext()).strip() for n in parent.iter() if local_name(n.tag) == "value"), "")
                        if value:
                            question_types.add(value)
        except Exception:
            pass
    item["ExternalUrls"] = sorted(urls)
    item["QuestionTypes"] = sorted(question_types)


def _rubrics(extracted_root: Path) -> list[dict]:
    path = extracted_root / "course_settings" / "rubrics.xml"
    if not path.exists():
        return []
    result = []
    for rubric in _nodes(parse_xml(path).getroot(), "rubric"):
        criteria = []
        for container in list(rubric):
            if local_name(container.tag) != "criteria":
                continue
            for criterion in list(container):
                if local_name(criterion.tag) != "criterion":
                    continue
                ratings = []
                for ratings_node in list(criterion):
                    if local_name(ratings_node.tag) == "ratings":
                        ratings.extend({"Description": child_text(r, "description"), "Points": child_text(r, "points"), "LongDescription": child_text(r, "long_description")} for r in list(ratings_node) if local_name(r.tag) == "rating")
                criteria.append({"Id": child_text(criterion, "criterion_id"), "Description": child_text(criterion, "description"), "Points": child_text(criterion, "points"), "RatingCount": len(ratings), "Ratings": ratings})
        result.append({"Identifier": rubric.attrib.get("identifier", ""), "Title": child_text(rubric, "title"), "PointsPossible": child_text(rubric, "points_possible"), "CriterionCount": len(criteria), "LevelsPerCriterion": [len(c["Ratings"]) for c in criteria], "AllCriteriaBinary": all(len(c["Ratings"]) == 2 for c in criteria), "Criteria": criteria})
    return result


def _export_xml_text(extracted_root: Path, evidence_root: Path) -> None:
    output_root = evidence_root / "xml_text"
    output_root.mkdir(parents=True, exist_ok=True)
    index, used = [], set()
    for path in sorted([p for p in extracted_root.rglob("*") if p.is_file() and p.suffix.lower() in {".xml", ".qti"} and p.stat().st_size <= 50_000_000]):
        try:
            root = parse_xml(path).getroot()
            chunks = []
            for node in root.iter():
                if local_name(node.tag) in {"text", "description", "message", "question_text", "body", "title", "display_name"}:
                    value = html_to_text(html.unescape("".join(node.itertext())))
                    if value and value not in chunks:
                        chunks.append(value)
            if not chunks:
                continue
            base = safe_slug(path.stem, 42)
            name, suffix = f"{base}.txt", 2
            while name in used:
                name = f"{base}-{suffix}.txt"; suffix += 1
            used.add(name)
            output = output_root / name
            relative = relative_unix(extracted_root, path)
            output.write_text(f"SOURCE: {relative}\n\n" + "\n\n".join(chunks), encoding="utf-8")
            index.append({"Source": relative, "TextFile": relative_unix(evidence_root, output), "Chunks": len(chunks)})
        except Exception:
            pass
    write_json(index, evidence_root / "xml_text_index.json")


def imscc_inventory(extracted_root: Path, evidence_root: Path) -> dict:
    manifest_path = extracted_root / "imsmanifest.xml"
    if not manifest_path.exists():
        raise ValueError("The package has no imsmanifest.xml.")
    manifest = parse_xml(manifest_path).getroot()
    resources, resource_map = [], {}
    for node in _nodes(manifest, "resource"):
        files = sorted(set(child.attrib.get("href", "") for child in list(node) if local_name(child.tag) == "file" and child.attrib.get("href")))
        resource = {"Identifier": node.attrib.get("identifier", ""), "Type": node.attrib.get("type", ""), "Href": node.attrib.get("href", ""), "Files": files}
        if resource["Identifier"]:
            resources.append(resource); resource_map[resource["Identifier"]] = resource
    summary = {"Title": None, "CourseCode": None, "DefaultView": None, "ResourceCount": len(resources), "ModuleCount": 0, "ItemCount": 0, "PublishedItemCount": 0, "Weeks": [], "ItemTypes": {}, "CourseSettings": {}, "PolicySettings": {}, "ExternalDomains": [], "InstructorFacingDocuments": [], "MissingReferencedFiles": [], "RubricCount": 0, "OrphanRubrics": []}
    settings_path = extracted_root / "course_settings" / "course_settings.xml"
    if settings_path.exists():
        settings = parse_xml(settings_path).getroot()
        summary.update({"Title": child_text(settings, "title"), "CourseCode": child_text(settings, "course_code"), "DefaultView": child_text(settings, "default_view")})
        for child in list(settings):
            text = "".join(child.itertext())
            if not list(child) and len(text) <= 10_000:
                summary["CourseSettings"][local_name(child.tag)] = text
    for filename in ("late_policy.xml", "assignment_groups.xml", "grading_standards.xml", "context.xml"):
        path = extracted_root / "course_settings" / filename
        if not path.exists(): continue
        try:
            for leaf in parse_xml(path).getroot().iter():
                if not list(leaf) and (leaf.text or "").strip():
                    summary["PolicySettings"].setdefault(f"{path.stem}.{local_name(leaf.tag)}", (leaf.text or "").strip())
        except Exception: pass
    modules, items = [], []
    module_path = extracted_root / "course_settings" / "module_meta.xml"
    if module_path.exists():
        for module_node in _nodes(parse_xml(module_path).getroot(), "module"):
            title, state = child_text(module_node, "title"), child_text(module_node, "workflow_state")
            module = {"Identifier": module_node.attrib.get("identifier", ""), "Title": title, "Position": int(child_text(module_node, "position") or 0), "WorkflowState": state, "RequireSequentialProgress": child_text(module_node, "require_sequential_progress") == "true", "UnlockAt": child_text(module_node, "unlock_at"), "Prerequisites": [], "CompletionRequirements": []}
            for node in list(module_node):
                if local_name(node.tag) == "prerequisites":
                    module["Prerequisites"] = [f"{p.attrib.get('type', '')}: {child_text(p, 'title') or ''} {child_text(p, 'identifierref') or ''}".strip() for p in list(node)]
                if local_name(node.tag) == "completionRequirements":
                    module["CompletionRequirements"] = [f"{p.attrib.get('type', '')}: " + ", ".join(f"{local_name(c.tag)}={''.join(c.itertext())}" for c in list(p)) for p in list(node)]
            modules.append(module)
            items_container = next((n for n in list(module_node) if local_name(n.tag) == "items"), None)
            for item_node in list(items_container or []):
                item_title, item_state = child_text(item_node, "title"), child_text(item_node, "workflow_state")
                identifier_ref = child_text(item_node, "identifierref")
                resource = resource_map.get(identifier_ref)
                published = state == "active" and item_state == "active"
                item = {"Identifier": item_node.attrib.get("identifier", ""), "IdentifierRef": identifier_ref, "ModuleIdentifier": module["Identifier"], "ModuleTitle": title, "ModulePosition": module["Position"], "Position": int(child_text(item_node, "position") or 0), "Week": _week_number(f"{title} {item_title}"), "Type": child_text(item_node, "content_type"), "Title": item_title, "WorkflowState": item_state, "Published": published, "StudentFacing": published and not _instructor_facing(f"{title} {item_title}"), "ResourceType": resource.get("Type") if resource else None, "ResourceHref": resource.get("Href") if resource else None, "Url": child_text(item_node, "url"), "Settings": {}, "ExternalUrls": [], "QuestionTypes": []}
                _add_item_details(item, resource, extracted_root); items.append(item)
    modules.sort(key=lambda value: value["Position"]); items.sort(key=lambda value: (value["ModulePosition"], value["Position"]))
    summary.update({"ModuleCount": len(modules), "ItemCount": len(items), "PublishedItemCount": sum(bool(i["Published"]) for i in items), "Weeks": sorted(set(i["Week"] for i in items if i["Week"])), "ItemTypes": dict(sorted(Counter(i["Type"] for i in items).items())), "InstructorFacingDocuments": sorted(set(f"{i['ModuleTitle']} / {i['Title']}" for i in items if _instructor_facing(f"{i['ModuleTitle']} {i['Title']}")))})
    summary["MissingReferencedFiles"] = sorted(set(file for resource in resources for file in resource["Files"] if not _resolve_package_path(extracted_root, file).exists()))
    domains = set()
    for item in items:
        for url in [item.get("Url"), *item["ExternalUrls"]]:
            if url and urllib.parse.urlparse(url).hostname: domains.add(urllib.parse.urlparse(url).hostname.lower())
    summary["ExternalDomains"] = sorted(domains)
    rubrics = _rubrics(extracted_root); references = {i["Settings"].get("rubric_identifierref") for i in items}
    summary["RubricCount"] = len(rubrics); summary["OrphanRubrics"] = [f"{r['Identifier']}: {r['Title']}" for r in rubrics if r["Identifier"] not in references]
    for name, value in (("course_summary.json", summary), ("modules.json", modules), ("items.json", items), ("resources.json", resources), ("rubrics.json", rubrics)): write_json(value, evidence_root / name)
    _export_xml_text(extracted_root, evidence_root)
    lines = ["# Deterministic course digest", "", f"- Title: {summary['Title']}", f"- Code: {summary['CourseCode']}", f"- Modules/items/published items: {len(modules)}/{len(items)}/{summary['PublishedItemCount']}", f"- Weeks detected: {', '.join(summary['Weeks'])}", f"- Home view: {summary['DefaultView']}", f"- External domains: {', '.join(summary['ExternalDomains'])}", "", "## Modules", ""]
    lines += [f"- {m['Position']}. {m['Title']} [{m['WorkflowState']}] sequential={m['RequireSequentialProgress']} unlock={m['UnlockAt']}; prerequisites={' | '.join(m['Prerequisites'])}" for m in modules]
    lines += ["", "## Items", ""] + [f"- {i['ModuleTitle']} > {i['Title']} | {i['Type']} | published={i['Published']} | href={i['ResourceHref']} | " + "; ".join(f"{k}={v}" for k, v in i["Settings"].items()) for i in items]
    (evidence_root / "course_digest.md").write_text("\n".join(lines), encoding="utf-8")
    return {"Summary": summary, "Modules": modules, "Items": items, "Resources": resources}
