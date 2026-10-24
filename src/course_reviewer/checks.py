from __future__ import annotations

from datetime import datetime
from pathlib import Path

from .common import relative_unix, write_json


def deterministic_checks(inventory: dict, html_results: list[dict], extracted_root: Path, evidence_root: Path) -> dict:
    graded, manual = [], []
    no_due_date, attempt_violations, discussion_mismatches = [], [], []
    week_stats: dict[str, dict] = {}
    for item in inventory["Items"]:
        settings = item.get("Settings", {})
        try: points = float(settings.get("points_possible", 0) or 0)
        except ValueError: points = 0
        grading_type, quiz_type = settings.get("grading_type"), settings.get("quiz_type")
        is_graded = points > 0 and grading_type != "not_graded"
        if quiz_type == "assignment": is_graded = True
        if not is_graded: continue
        graded.append(item)
        week = item.get("Week") or "unknown"
        stats = week_stats.setdefault(week, {"GradedItems": 0, "ManualItems": 0, "DueWeekdays": [], "ItemsWithoutDueDate": 0})
        stats["GradedItems"] += 1
        due = settings.get("due_at")
        if not due:
            no_due_date.append(f"{item['ModuleTitle']} > {item['Title']}"); stats["ItemsWithoutDueDate"] += 1
        else:
            try: stats["DueWeekdays"].append(datetime.fromisoformat(due.replace("Z", "+00:00")).strftime("%A"))
            except ValueError: pass
        submission = settings.get("submission_types", "")
        question_types = item.get("QuestionTypes", [])
        is_manual = (item.get("Type") == "Assignment" and any(value in submission for value in ("online_upload", "online_text_entry", "online_url", "media_recording", "on_paper"))) or "Discussion" in (item.get("Type") or "") or (quiz_type == "assignment" and any(q in {"essay_question", "file_upload_question"} for q in question_types))
        if is_manual:
            manual.append(item); stats["ManualItems"] += 1
            try:
                attempts = int(settings.get("allowed_attempts", ""))
                if attempts < 1 or attempts > 3: attempt_violations.append(f"{item['Title']}: allowed_attempts={attempts}")
            except ValueError: pass
        if "Discussion" in (item.get("Type") or "") and due and due != settings.get("lock_at"):
            discussion_mismatches.append(f"{item['Title']}: due_at={due}; lock_at={settings.get('lock_at')}")
    for stats in week_stats.values(): stats["DueWeekdays"] = sorted(set(stats["DueWeekdays"]))
    accessibility_fields = {
        "HtmlDocuments": len(html_results), "Images": "ImageCount", "MissingOrBadAlt": "MissingAltCount",
        "HeadingOrderIssues": "HeadingOrderIssueCount", "TablesWithoutHeaders": "TableWithoutHeaderCount",
        "VagueLinks": "VagueLinkCount", "InlineColorDeclarations": "InlineColorCount", "LongSentences": "LongSentenceCount",
    }
    accessibility = {key: (value if isinstance(value, int) else sum(int(item.get(value, 0) or 0) for item in html_results)) for key, value in accessibility_fields.items()}
    docs = sorted(relative_unix(extracted_root, p) for p in extracted_root.rglob("*") if p.is_file() and p.suffix.lower() in {".pdf", ".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt"})
    media = [{"Path": relative_unix(extracted_root, p), "Bytes": p.stat().st_size} for p in extracted_root.rglob("*") if p.is_file() and p.suffix.lower() in {".mp4", ".mov", ".m4v", ".mp3", ".wav"} and p.stat().st_size > 25 * 1024 * 1024]
    gates = [{"Module": m["Title"], "UnlockAt": m["UnlockAt"], "Prerequisites": m["Prerequisites"], "CompletionRequirements": m["CompletionRequirements"]} for m in inventory["Modules"] if m["UnlockAt"] or m["Prerequisites"] or m["CompletionRequirements"]]
    result = {"GradedItemCount": len(graded), "ManuallyGradedItemCount": len(manual), "WeekStatistics": week_stats, "GradedItemsWithoutDueDate": no_due_date, "ManualItemsOutsideOneToThreeAttempts": attempt_violations, "GradedDiscussionDueUntilMismatches": discussion_mismatches, "ModuleGates": gates, "AccessibilityTotals": accessibility, "DocumentsRequiringManualAccessibilityReview": docs, "LargeMediaOver25MB": media}
    write_json(result, evidence_root / "deterministic_checks.json")
    return result
