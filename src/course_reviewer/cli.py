from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .controller import finalize, list_courses, next_task, prepare, rebuild_office, resolve_run, status
from .validation import validate_findings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Local, no-API IMSCC course reviewer")
    parser.add_argument("command", choices=("list", "prepare", "status", "next", "validate", "finalize", "rebuild-office"))
    parser.add_argument("target", nargs="?", help="Course query for prepare, or run path for other commands")
    parser.add_argument("--root", default=None, help="Workspace root (defaults to the folder containing course_review.py)")
    parser.add_argument("--workbook", help="Explicit sidecar .xlsx workbook")
    parser.add_argument("--output", help="Alternate parent directory for generated runs")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    default_root = Path(__file__).resolve().parents[2]
    root = Path(args.root).resolve() if args.root else default_root
    try:
        if args.command == "list": result = list_courses(root)
        elif args.command == "prepare":
            if not args.target: raise ValueError("prepare requires a course name, code, or .imscc path.")
            result = prepare(root, args.target, args.workbook, args.output)
        elif args.command == "status": result = status(root, args.target)
        elif args.command == "next": result = next_task(root, args.target)
        elif args.command == "validate":
            validation = validate_findings(resolve_run(root, args.target))
            result = {key: validation[key] for key in ("IsValid", "Errors", "Warnings", "ExpectedCriteria", "CompletedCriteria")}
        elif args.command == "finalize": result = finalize(root, args.target)
        else: result = rebuild_office(root, args.target)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if args.command == "validate" and not result["IsValid"]: return 2
        if args.command == "finalize" and not result["Validation"]["IsValid"]: return 2
        return 0
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
