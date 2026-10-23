[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\ArchiveWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\OfficeWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\ValidationWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\PacketWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\WorkbookWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Workers\PacketWorker.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\CourseReviewer\Common.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$script:passed = 0
$script:failed = 0

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CourseReviewerTests-" + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Invoke-Test 'rejects ZIP path traversal' {
        $zipPath = Join-Path $tempRoot 'traversal.zip'
        $stream = New-Object System.IO.FileStream($zipPath, [System.IO.FileMode]::CreateNew)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try { $entry = $zip.CreateEntry('../escape.txt'); $writer = New-Object System.IO.StreamWriter($entry.Open()); try { $writer.Write('bad') } finally { $writer.Dispose() } }
            finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
        $threw = $false
        try { Expand-SafeArchive -ArchivePath $zipPath -Destination (Join-Path $tempRoot 'traversal-out') } catch { $threw = $true }
        Assert-True $threw 'Traversal archive was not rejected.'
        Assert-True (-not [System.IO.File]::Exists((Join-Path $tempRoot 'escape.txt'))) 'Traversal created a file outside the destination.'
    }

    Invoke-Test 'expands and rebuilds an XLSX package' {
        $fixture = Join-Path $tempRoot 'xlsx-fixture'; [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'xl\_rels')) | Out-Null; [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'xl\worksheets')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $fixture '[Content_Types].xml'), '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\workbook.xml'), '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Course Map" sheetId="1" r:id="rId1"/></sheets></workbook>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\_rels\workbook.xml.rels'), '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\worksheets\sheet1.xml'), '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Hello</t></is></c></row></sheetData></worksheet>')
        $xlsx = Join-Path $tempRoot 'fixture.xlsx'; [System.IO.Compression.ZipFile]::CreateFromDirectory($fixture, $xlsx)
        $run = Join-Path $tempRoot 'run'; $office = Join-Path $run 'office_xml'; [System.IO.Directory]::CreateDirectory($office) | Out-Null
        $artifact = Expand-OfficeDocument -SourcePath $xlsx -RunPath $run -OfficeRoot $office
        $normalized = Join-Path $run ($artifact.NormalizedXml.Replace('/', '\'))
        Assert-True ([System.IO.File]::ReadAllText($normalized).Contains('Hello')) 'Normalized XML did not contain the cell value.'
        Assert-True (@($artifact.ReviewFiles).Count -eq 1) 'Expected one visible-sheet review view.'
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $run ($artifact.ReviewFiles[0].Replace('/', '\')))).Contains('Hello')) 'Visible-sheet TSV did not contain the cell value.'
        $rebuilt = Restore-OfficeDocument -Artifact $artifact -RunPath $run
        $check = [System.IO.Compression.ZipFile]::OpenRead($rebuilt); try { Assert-True ($null -ne $check.GetEntry('[Content_Types].xml')) 'Rebuilt XLSX is missing [Content_Types].xml.' } finally { $check.Dispose() }
    }

    Invoke-Test 'expands and rebuilds a DOCX package' {
        $fixture = Join-Path $tempRoot 'docx-fixture'; [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'word')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $fixture '[Content_Types].xml'), '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'word\document.xml'), '<?xml version="1.0" encoding="utf-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Résumé — 日本語</w:t></w:r></w:p></w:body></w:document>', (New-Object System.Text.UTF8Encoding($false)))
        $docx = Join-Path $tempRoot 'fixture.docx'; [System.IO.Compression.ZipFile]::CreateFromDirectory($fixture, $docx)
        $run = Join-Path $tempRoot 'docx-run'; $office = Join-Path $run 'office_xml'; [System.IO.Directory]::CreateDirectory($office) | Out-Null
        $artifact = Expand-OfficeDocument -SourcePath $docx -RunPath $run -OfficeRoot $office
        $normalized = Join-Path $run ($artifact.NormalizedXml.Replace('/', '\'))
        Assert-True ([System.IO.File]::ReadAllText($normalized).Contains('Résumé — 日本語')) 'Normalized XML did not preserve Unicode paragraph text.'
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $run ($artifact.ReviewFiles[0].Replace('/', '\'))), [System.Text.Encoding]::UTF8).Contains('Résumé — 日本語')) 'DOCX review text did not preserve Unicode.'
        $rebuilt = Restore-OfficeDocument -Artifact $artifact -RunPath $run
        $check = [System.IO.Compression.ZipFile]::OpenRead($rebuilt); try { Assert-True ($null -ne $check.GetEntry('word/document.xml')) 'Rebuilt DOCX is missing word/document.xml.' } finally { $check.Dispose() }
    }

    Invoke-Test 'resolves the required workbook beside its IMSCC' {
        $folder = Join-Path $tempRoot 'resolver'; [System.IO.Directory]::CreateDirectory($folder) | Out-Null
        $imscc = Join-Path $folder 'PUBH132.imscc'; [System.IO.File]::WriteAllText($imscc, '')
        $xlsx = Join-Path $folder 'PUBH 132 Course Workbook.xlsx'; [System.IO.File]::WriteAllText($xlsx, '')
        $course = [pscustomobject]@{ Path = $imscc; FileName = 'PUBH132.imscc'; CourseCode = 'PUBH132 (English Master)' }
        $resolved = Resolve-CourseWorkbook -Root $folder -Course $course
        Assert-True ($resolved -eq $xlsx) "Resolved the wrong workbook: $resolved"
    }

    Invoke-Test 'maps and updates the exact Design Review tab without overwriting human notes' {
        $fixture = Join-Path $tempRoot 'design-review-fixture'
        [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'xl\_rels')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'xl\worksheets')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $fixture '[Content_Types].xml'), '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\workbook.xml'), '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Design Review" sheetId="1" r:id="rId1"/></sheets></workbook>')
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\_rels\workbook.xml.rels'), '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        $sheetXml = '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="7"><c r="B7" t="inlineStr"><is><t>Criteria</t></is></c><c r="E7" t="inlineStr"><is><t>Status</t></is></c><c r="F7" t="inlineStr"><is><t>Reviewer Notes (Human)</t></is></c></row><row r="9"><c r="A9" t="inlineStr"><is><t>1.11</t></is></c><c r="B9" t="inlineStr"><is><t>Outcomes criterion</t></is></c><c r="E9" t="inlineStr"><is><t>- - -</t></is></c><c r="F9" t="inlineStr"><is><t>Keep this human note</t></is></c></row><row r="21"><c r="A21" t="inlineStr"><is><t>3.1</t></is></c><c r="B21" t="inlineStr"><is><t>Small groups</t></is></c><c r="E21" t="inlineStr"><is><t>- - -</t></is></c></row></sheetData></worksheet>'
        [System.IO.File]::WriteAllText((Join-Path $fixture 'xl\worksheets\sheet1.xml'), $sheetXml)
        $xlsx = Join-Path $tempRoot 'design-review.xlsx'; [System.IO.Compression.ZipFile]::CreateFromDirectory($fixture, $xlsx)
        $run = Join-Path $tempRoot 'design-review-run'; $office = Join-Path $run 'office_xml'; [System.IO.Directory]::CreateDirectory((Join-Path $run 'findings')) | Out-Null
        $artifact = Expand-OfficeDocument -SourcePath $xlsx -RunPath $run -OfficeRoot $office
        $result = Write-DesignReviewContract -Artifact $artifact -RunPath $run -BaselinePath (Join-Path $repoRoot 'course_review_agent_instructions.md')
        Assert-True (@($result.Contract.Criteria).Count -eq 2) 'Expected two mapped Design Review criteria.'
        Assert-True (@($result.Contract.Criteria | Where-Object Id -eq '3.10').Count -eq 1) 'Excel value 3.1 was not mapped to criterion 3.10.'
        Write-JsonFile ([pscustomobject]@{ criterion_id='1.11'; criterion_title='Outcomes'; status='Verified'; confidence='High'; evidence=@('Direct evidence'); issues=@(); recommendations=@(); needs_from_requester=@() }) (Join-Path $run 'findings\1.11.json')
        Write-JsonFile ([pscustomobject]@{ criterion_id='3.10'; criterion_title='Small groups'; status='Unable to Verify'; confidence='Low'; evidence=@(); issues=@('Missing setup notes'); recommendations=@('Provide setup notes'); needs_from_requester=@('Setup notes') }) (Join-Path $run 'findings\3.10.json')
        $update = Update-DesignReviewWorkbook -Artifact $artifact -RunPath $run -Contract $result.Contract
        $updatedSheet = Read-XmlFile (Join-Path $run ($artifact.PackageDirectory.Replace('/', '\') + '\xl\worksheets\sheet1.xml'))
        $cellText = @{}; foreach($cell in $updatedSheet.SelectNodes("//*[local-name()='c']")){ $cellText[$cell.GetAttribute('r')] = (@($cell.SelectNodes(".//*[local-name()='t']") | ForEach-Object InnerText) -join '') }
        Assert-True ($cellText['E9'] -eq 'Verified') 'Mapped workbook status was not written.'
        Assert-True ($cellText['E21'] -eq '- - -') 'Unable to Verify should preserve the workbook status cell.'
        Assert-True ($cellText['F9'] -eq 'Keep this human note') 'Existing human review notes were overwritten.'
        Assert-True ($cellText['J9'] -like 'Automated review: Verified.*') 'Automated notes were not written to column J.'
        Assert-True ($cellText['J21'] -like 'Automated review: Unable to Verify.*') 'Unable-to-verify rationale was not written.'
    }

    Invoke-Test 'round-trips UTF-8 JSON without mojibake' {
        $path = Join-Path $tempRoot 'unicode.json'
        $expected = 'Résumé — café 日本語'
        Write-JsonFile ([pscustomobject]@{ Text = $expected }) $path
        $actual = Read-JsonFile $path
        Assert-True ($actual.Text -eq $expected) "UTF-8 JSON changed from '$expected' to '$($actual.Text)'."
    }

    Invoke-Test 'validates the snake_case worker contract' {
        $run = Join-Path $tempRoot 'validation-run'; [System.IO.Directory]::CreateDirectory((Join-Path $run 'tasks')) | Out-Null; [System.IO.Directory]::CreateDirectory((Join-Path $run 'findings')) | Out-Null
        $criterion = [pscustomobject]@{ Id = '1.11'; Label = '1.11'; Title = 'Outcomes'; Category = 'Category 1'; Required = $false; Wwo = $false; Instructions = '' }
        Write-JsonFile $criterion (Join-Path $run 'tasks\criteria.json')
        $finding = [pscustomobject][ordered]@{ criterion_id = '1.11'; criterion_title = 'Outcomes'; status = 'Verified'; confidence = 'High'; evidence = @('imsmanifest.xml — direct evidence'); issues = @(); recommendations = @(); needs_from_requester = @() }
        Write-JsonFile $finding (Join-Path $run 'findings\1.11.json')
        $validation = Test-ReviewFindings $run
        Assert-True $validation.IsValid ($validation.Errors -join '; ')
    }

    Invoke-Test 'parses every baseline criterion' {
        $baseline = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'course_review_agent_instructions.md'))
        $criteria = @(Get-CriterionDefinitions -Markdown $baseline)
        Assert-True ($criteria.Count -eq 38) "Expected 38 criteria; found $($criteria.Count)."
        Assert-True (@($criteria | Where-Object Id -eq 'WWO-GRADING-QUEUE').Count -eq 1) 'Stable WWO criterion ID was not generated.'
    }
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTemp.StartsWith($systemTemp, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Path]::GetFileName($resolvedTemp).StartsWith('CourseReviewerTests-')) {
        [System.IO.Directory]::Delete($resolvedTemp, $true)
    }
}

Write-Host "`n$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
