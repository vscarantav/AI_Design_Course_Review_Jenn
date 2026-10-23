# IMSCC Course Reviewer

A local controller/worker application for reviewing Canvas IMSCC exports in the ChatGPT desktop/Codex environment. It uses no model API and requires no downloaded dependencies.

Open this folder in ChatGPT and say:

> Evaluate course PUBH 132.

Place both the course `.imscc` export and its course workbook `.xlsx` in this folder first. The workbook must contain the exact tab name `Design Review`.

Or run preparation directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-CourseReview.ps1 prepare "PUBH 132"
```

Generated review work is stored under `.course-review/runs/` and ignored by Git. The source `.imscc`, `.docx`, and `.xlsx` files are never overwritten. Finalization returns a completed copy of the workbook under `output/rebuilt_office/` plus a complete Markdown audit.

The controller exposes resumable progress with `status` and `next`; ChatGPT processes one bounded category packet at a time until all findings validate.

See `App_architecture.md` for the complete agent workflow and `IMPLEMENTATION_PLAN.md` for design decisions.
