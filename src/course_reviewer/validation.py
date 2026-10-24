from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any

from .common import finding_filename, read_json
from .docx_report import write_docx_report

STATUSES = {"Verified", "In Progress", "Needs Attention", "Exempt", "Unable to Verify"}
CONFIDENCES = {"High", "Medium", "Low"}


def _field(value: dict, *names: str, default=None):
    for name in names:
        if name in value:
            return value[name]
    return default


def validate_findings(run_path: Path) -> dict:
    criteria_path = run_path / "tasks" / "criteria.json"
    if not criteria_path.exists():
        raise ValueError("Run has no tasks/criteria.json.")
    criteria = read_json(criteria_path)
    errors: list[str] = []
    warnings: list[str] = []
    findings: list[dict] = []
    for criterion in criteria:
        path = run_path / "findings" / finding_filename(criterion["Id"])
        if not path.exists():
            errors.append(f"Missing finding for {criterion['Id']}: findings/{path.name}")
            continue
        try:
            raw = read_json(path)
            finding = {
                "CriterionId": _field(raw, "criterion_id", "CriterionId"),
                "CriterionTitle": _field(raw, "criterion_title", "CriterionTitle"),
                "Status": _field(raw, "status", "Status"),
                "Confidence": _field(raw, "confidence", "Confidence"),
                "Evidence": list(_field(raw, "evidence", "Evidence", default=[]) or []),
                "Issues": list(_field(raw, "issues", "Issues", default=[]) or []),
                "Recommendations": list(_field(raw, "recommendations", "Recommendations", default=[]) or []),
                "NeedsFromRequester": list(_field(raw, "needs_from_requester", "NeedsFromRequester", default=[]) or []),
            }
        except Exception as exc:
            errors.append(f"Invalid finding file for {criterion['Id']}: {exc}")
            continue
        if finding["CriterionId"] != criterion["Id"]:
            errors.append(f"Finding {path.name} says criterion_id '{finding['CriterionId']}', expected '{criterion['Id']}'.")
        if finding["Status"] not in STATUSES:
            errors.append(f"{criterion['Id']} has invalid status '{finding['Status']}'.")
        if finding["Confidence"] not in CONFIDENCES:
            errors.append(f"{criterion['Id']} has invalid confidence '{finding['Confidence']}'.")
        if finding["Status"] == "Verified" and not finding["Evidence"]:
            errors.append(f"{criterion['Id']} is Verified but cites no evidence.")
        if finding["Status"] not in {"Verified", "Exempt"} and not finding["Recommendations"]:
            errors.append(f"{criterion['Id']} is {finding['Status']} but has no recommendation.")
        if criterion["Required"] and finding["Status"] not in {"Verified", "Exempt"}:
            warnings.append(f"Priority finding: required criterion {criterion['Id']} is {finding['Status']}.")
        findings.append({"Criterion": criterion, "Finding": finding})
    return {
        "IsValid": not errors,
        "Errors": errors,
        "Warnings": warnings,
        "ExpectedCriteria": len(criteria),
        "CompletedCriteria": len(findings),
        "Findings": findings,
    }


def _add_list(lines: list[str], label: str, values: list[Any]) -> None:
    lines.append(f"{label}:")
    lines.extend(f"- {value}" for value in values) if values else lines.append("- None.")


def write_report(run_path: Path, run: dict, validation: dict) -> dict[str, Path]:
    summary = read_json(run_path / "evidence" / "course_summary.json")
    output = run_path / "output" / "course_review.md"
    output.parent.mkdir(parents=True, exist_ok=True)
    display = summary.get("CourseCode") or summary.get("Title") or Path(run["SourcePackage"]).stem
    lines = [
        f"# Course Review - {display}", "",
        f"- Course title: {summary.get('Title') or ''}",
        f"- Course code: {summary.get('CourseCode') or ''}",
        f"- Source package: {Path(run['SourcePackage']).name}",
        f"- Source SHA-256: `{run['SourceSha256']}`",
        f"- Course workbook: {Path(run['SourceWorkbook']).name}",
        f"- Workbook SHA-256: `{run['WorkbookSha256']}`",
        f"- Review generated: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %z')}",
        f"- Modules / items / published items: {summary.get('ModuleCount', 0)} / {summary.get('ItemCount', 0)} / {summary.get('PublishedItemCount', 0)}",
    ]
    contract_path = run_path / run["DesignReviewContract"]
    if contract_path.exists():
        contract = read_json(contract_path)
        lines.append(f"- Workbook scorecard mapping: {len(contract['Criteria'])} criteria mapped; {len(contract['MissingBaselineCriteria'])} retained in this audit only")
    lines += ["", "Deterministic inventories are in `evidence/`; extracted source text is in `evidence/text/` and `evidence/xml_text/`.", ""]
    current_category = None
    for pair in validation["Findings"]:
        criterion, finding = pair["Criterion"], pair["Finding"]
        if criterion["Category"] != current_category:
            current_category = criterion["Category"]
            lines += [f"## {current_category}", ""]
        required = " *" if criterion["Required"] else ""
        wwo = " [WWO]" if criterion["Wwo"] else ""
        lines += [f"### {criterion['Id']} - {criterion['Title']}{required}{wwo}", f"Status: {finding['Status']}  ", f"Confidence: {finding['Confidence']}"]
        _add_list(lines, "Evidence", finding["Evidence"])
        _add_list(lines, "Issues", finding["Issues"])
        _add_list(lines, "Recommendations", finding["Recommendations"])
        _add_list(lines, "Needs from requester", finding["NeedsFromRequester"])
        lines.append("")
    for name in ("contradictions.md", "not_reviewed.md", "settings_and_assumptions.md", "prior_review_comparison.md"):
        path = run_path / "findings" / name
        if path.exists():
            lines += ["", path.read_text(encoding="utf-8-sig"), ""]
    output.write_text("\n".join(lines), encoding="utf-8")
    return {"Docx": write_docx_report(run_path, run, validation), "Markdown": output}
