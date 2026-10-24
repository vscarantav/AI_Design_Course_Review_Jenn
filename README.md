# IMSCC Course Reviewer

A local, cross-platform controller/worker application for reviewing Canvas IMSCC exports in ChatGPT desktop or Codex. It uses no model API and runs on Python 3.10+ on Windows and macOS.

For trusted Codex projects, `.codex/config.toml` defaults new threads to GPT-6.1 Sol with high reasoning. Explicit per-session or CLI model choices still take precedence; see `AGENTS.md` for the fallback policy.

Open this folder in ChatGPT and say:

> Evaluate course PUBH 132.

Place both the course `.imscc` export and its course workbook `.xlsx` in this folder first. The workbook must contain the exact tab name `Design Review`.

## Setup

Create an isolated environment and install declared dependencies (there are currently no third-party runtime packages):

```text
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

On Windows, use:

```text
py -3 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
```

If Python is missing, `AGENTS.md` contains terminal installation commands for both operating systems.

## Run

macOS:

```text
.venv/bin/python course_review.py prepare "PUBH 132"
```

Windows:

```text
.venv\Scripts\python.exe course_review.py prepare "PUBH 132"
```

The CLI also exposes `list`, `status`, `next`, `validate`, `finalize`, and `rebuild-office`. Generated work is stored under `.course-review/runs/` and ignored by Git. Source `.imscc`, `.docx`, and `.xlsx` files are never overwritten. Finalization creates a completed workbook copy under `output/rebuilt_office/`, a formatted Word report at `output/course_review.docx`, and a secondary machine-readable Markdown audit.

Run tests with `python -m unittest discover -s tests -v` (or the corresponding `.venv` interpreter).

See `App_architecture.md` for the complete agent workflow and `IMPLEMENTATION_PLAN.md` for design decisions.
