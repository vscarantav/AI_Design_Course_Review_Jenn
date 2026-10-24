from __future__ import annotations

import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

from src.course_reviewer.archive import compress_directory, expand_safe_archive
from src.course_reviewer.common import read_json, write_json
from src.course_reviewer.docx_report import write_docx_report
from src.course_reviewer.office import expand_office_document, parse_xml, restore_office_document
from src.course_reviewer.packets import criterion_definitions
from src.course_reviewer.validation import validate_findings
from src.course_reviewer.workbook import resolve_course_workbook, update_design_review_workbook, write_design_review_contract

ROOT = Path(__file__).resolve().parents[1]


def make_zip(source: Path, destination: Path) -> None:
    compress_directory(source, destination)


class CourseReviewerTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="CourseReviewerTests-"))

    def tearDown(self):
        shutil.rmtree(self.temp)

    def test_rejects_zip_path_traversal(self):
        archive = self.temp / "traversal.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../escape.txt", "bad")
        with self.assertRaises(ValueError):
            expand_safe_archive(archive, self.temp / "out")
        self.assertFalse((self.temp / "escape.txt").exists())

    def test_disambiguates_case_only_imscc_collisions(self):
        archive = self.temp / "case-collision.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("media/Gateway.png", b"first")
            output.writestr("media/gateway.png", b"second")
        destination = self.temp / "out"
        path_map = expand_safe_archive(archive, destination, collision_policy="rename")
        self.assertEqual(1, len(path_map))
        files = [path for path in destination.rglob("*") if path.is_file()]
        self.assertEqual(2, len(files))
        self.assertEqual({b"first", b"second"}, {path.read_bytes() for path in files})

    def test_expands_and_rebuilds_xlsx(self):
        fixture = self.temp / "xlsx-fixture"
        (fixture / "xl" / "_rels").mkdir(parents=True)
        (fixture / "xl" / "worksheets").mkdir()
        (fixture / "[Content_Types].xml").write_text('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>', encoding="utf-8")
        (fixture / "xl" / "workbook.xml").write_text('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Course Map" sheetId="1" r:id="rId1"/></sheets></workbook>', encoding="utf-8")
        (fixture / "xl" / "_rels" / "workbook.xml.rels").write_text('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>', encoding="utf-8")
        (fixture / "xl" / "worksheets" / "sheet1.xml").write_text('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Hello</t></is></c></row></sheetData></worksheet>', encoding="utf-8")
        xlsx = self.temp / "fixture.xlsx"; make_zip(fixture, xlsx)
        run = self.temp / "run"; office = run / "office_xml"; office.mkdir(parents=True)
        artifact = expand_office_document(xlsx, run, office)
        self.assertIn("Hello", (run / artifact["NormalizedXml"]).read_text(encoding="utf-8"))
        self.assertEqual(1, len(artifact["ReviewFiles"]))
        self.assertIn("Hello", (run / artifact["ReviewFiles"][0]).read_text(encoding="utf-8-sig"))
        rebuilt = restore_office_document(artifact, run)
        with zipfile.ZipFile(rebuilt) as archive:
            self.assertIn("[Content_Types].xml", archive.namelist())

    def test_expands_and_rebuilds_docx_unicode(self):
        fixture = self.temp / "docx-fixture"; (fixture / "word").mkdir(parents=True)
        (fixture / "[Content_Types].xml").write_text('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>', encoding="utf-8")
        text = "Résumé — 日本語"
        (fixture / "word" / "document.xml").write_text(f'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:body></w:document>', encoding="utf-8")
        docx = self.temp / "fixture.docx"; make_zip(fixture, docx)
        run = self.temp / "run"; (run / "office_xml").mkdir(parents=True)
        artifact = expand_office_document(docx, run, run / "office_xml")
        self.assertIn(text, (run / artifact["NormalizedXml"]).read_text(encoding="utf-8"))
        self.assertIn(text, (run / artifact["ReviewFiles"][0]).read_text(encoding="utf-8-sig"))

    def test_resolves_matching_workbook(self):
        folder = self.temp / "resolver"; folder.mkdir()
        imscc = folder / "PUBH132.imscc"; imscc.write_bytes(b"")
        xlsx = folder / "PUBH 132 Course Workbook.xlsx"; xlsx.write_bytes(b"")
        course = {"Path": str(imscc), "FileName": imscc.name, "CourseCode": "PUBH132 (English Master)"}
        self.assertEqual(xlsx.resolve(), resolve_course_workbook(folder, course))

    def test_maps_and_updates_design_review(self):
        fixture = self.temp / "design-review-fixture"
        (fixture / "xl" / "_rels").mkdir(parents=True); (fixture / "xl" / "worksheets").mkdir()
        (fixture / "[Content_Types].xml").write_text('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>', encoding="utf-8")
        (fixture / "xl" / "workbook.xml").write_text('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Design Review" sheetId="1" r:id="rId1"/></sheets></workbook>', encoding="utf-8")
        (fixture / "xl" / "_rels" / "workbook.xml.rels").write_text('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>', encoding="utf-8")
        sheet_xml = '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="7"><c r="B7" t="inlineStr"><is><t>Criteria</t></is></c><c r="E7" t="inlineStr"><is><t>Status</t></is></c><c r="F7" t="inlineStr"><is><t>Reviewer Notes (Human)</t></is></c></row><row r="9"><c r="A9" t="inlineStr"><is><t>1.11</t></is></c><c r="B9" t="inlineStr"><is><t>Outcomes criterion</t></is></c><c r="E9" t="inlineStr"><is><t>- - -</t></is></c><c r="F9" t="inlineStr"><is><t>Keep this human note</t></is></c></row><row r="21"><c r="A21" t="inlineStr"><is><t>3.1</t></is></c><c r="B21" t="inlineStr"><is><t>Small groups</t></is></c><c r="E21" t="inlineStr"><is><t>- - -</t></is></c></row></sheetData></worksheet>'
        sheet_xml = sheet_xml.replace('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">', '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac" mc:Ignorable="x14ac">')
        (fixture / "xl" / "worksheets" / "sheet1.xml").write_text(sheet_xml, encoding="utf-8")
        xlsx = self.temp / "design-review.xlsx"; make_zip(fixture, xlsx)
        run = self.temp / "run"; (run / "office_xml").mkdir(parents=True); (run / "findings").mkdir()
        artifact = expand_office_document(xlsx, run, run / "office_xml")
        result = write_design_review_contract(artifact, run, ROOT / "course_review_agent_instructions.md")
        self.assertEqual(2, len(result["Contract"]["Criteria"]))
        self.assertIn("3.10", {item["Id"] for item in result["Contract"]["Criteria"]})
        write_json({"criterion_id": "1.11", "criterion_title": "Outcomes", "status": "Verified", "confidence": "High", "evidence": ["Direct evidence"], "issues": [], "recommendations": [], "needs_from_requester": []}, run / "findings" / "1.11.json")
        write_json({"criterion_id": "3.10", "criterion_title": "Small groups", "status": "Unable to Verify", "confidence": "Low", "evidence": [], "issues": ["Missing setup notes"], "recommendations": ["Provide setup notes"], "needs_from_requester": ["Setup notes"]}, run / "findings" / "3.10.json")
        update_design_review_workbook(artifact, run, result["Contract"])
        root = parse_xml(run / artifact["PackageDirectory"] / "xl" / "worksheets" / "sheet1.xml").getroot()
        values = {}
        for cell in (n for n in root.iter() if n.tag.rsplit("}", 1)[-1] == "c"):
            values[cell.attrib["r"]] = "".join((n.text or "") for n in cell.iter() if n.tag.rsplit("}", 1)[-1] == "t")
        self.assertEqual("Verified", values["E9"])
        self.assertEqual("- - -", values["E21"])
        self.assertEqual("Keep this human note", values["F9"])
        self.assertTrue(values["J9"].startswith("Automated review: Verified."))
        updated_xml = (run / artifact["PackageDirectory"] / "xl" / "worksheets" / "sheet1.xml").read_text(encoding="utf-8")
        self.assertIn('xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac"', updated_xml)
        self.assertIn('mc:Ignorable="x14ac"', updated_xml)

    def test_round_trips_utf8_json(self):
        expected = "Résumé — café 日本語"
        path = self.temp / "unicode.json"; write_json({"Text": expected}, path)
        self.assertEqual(expected, read_json(path)["Text"])

    def test_writes_primary_word_report(self):
        run_path = self.temp / "report-run"
        (run_path / "evidence").mkdir(parents=True)
        write_json({"Title": "Example Course", "CourseCode": "EX 101", "ModuleCount": 2, "ItemCount": 5, "PublishedItemCount": 4}, run_path / "evidence" / "course_summary.json")
        run = {"SourcePackage": str(self.temp / "EX101.imscc"), "SourceWorkbook": str(self.temp / "EX 101 Course Workbook.xlsx")}
        validation = {"Findings": [{"Criterion": {"Id": "1.11", "Title": "Learning outcomes", "Category": "Category 1 — Outcomes", "Required": True, "Wwo": False}, "Finding": {"Status": "Verified", "Confidence": "High", "Evidence": ["Direct evidence"], "Issues": [], "Recommendations": [], "NeedsFromRequester": []}}]}
        report = write_docx_report(run_path, run, validation)
        self.assertTrue(report.exists())
        with zipfile.ZipFile(report) as archive:
            self.assertIn("[Content_Types].xml", archive.namelist())
            document = archive.read("word/document.xml")
        self.assertIn(b"Course Review EX 101", document)
        self.assertIn(b"Direct evidence", document)

    def test_validates_snake_case_contract(self):
        run = self.temp / "run"; (run / "tasks").mkdir(parents=True); (run / "findings").mkdir()
        write_json([{"Id": "1.11", "Label": "1.11", "Title": "Outcomes", "Category": "Category 1", "Required": False, "Wwo": False, "Instructions": ""}], run / "tasks" / "criteria.json")
        write_json({"criterion_id": "1.11", "criterion_title": "Outcomes", "status": "Verified", "confidence": "High", "evidence": ["imsmanifest.xml — direct evidence"], "issues": [], "recommendations": [], "needs_from_requester": []}, run / "findings" / "1.11.json")
        self.assertTrue(validate_findings(run)["IsValid"])

    def test_parses_every_baseline_criterion(self):
        criteria = criterion_definitions((ROOT / "course_review_agent_instructions.md").read_text(encoding="utf-8-sig"))
        self.assertEqual(38, len(criteria))
        self.assertIn("WWO-GRADING-QUEUE", {item["Id"] for item in criteria})


if __name__ == "__main__":
    unittest.main(verbosity=2)
