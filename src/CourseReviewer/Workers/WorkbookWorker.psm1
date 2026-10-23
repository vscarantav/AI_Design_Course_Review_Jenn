Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PacketWorker.psm1')

function Resolve-CourseWorkbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Course,
        [string]$WorkbookPath
    )
    if ($WorkbookPath) {
        $candidate = if ([System.IO.Path]::IsPathRooted($WorkbookPath)) { [System.IO.Path]::GetFullPath($WorkbookPath) } else { [System.IO.Path]::GetFullPath((Join-Path $Root $WorkbookPath)) }
        if (-not [System.IO.File]::Exists($candidate)) { throw "Course workbook not found: $candidate" }
        if ([System.IO.Path]::GetExtension($candidate) -ne '.xlsx') { throw "Course workbook must be an .xlsx file: $candidate" }
        return $candidate
    }

    $courseDirectory = Split-Path -Parent $Course.Path
    $candidates = @(Get-ChildItem -LiteralPath $courseDirectory -Filter '*.xlsx' -File)
    if ($candidates.Count -eq 0) { throw "No course workbook was found beside $($Course.FileName). Place the course .xlsx workbook in $courseDirectory." }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }

    $packageKey = ConvertTo-NormalizedKey ([System.IO.Path]::GetFileNameWithoutExtension($Course.FileName))
    $courseCodeKey = ''
    $codeMatch = [regex]::Match([string]$Course.CourseCode, '(?i)\b[A-Z]{2,}\s*[- ]?\s*\d+[A-Z]?\b')
    if ($codeMatch.Success) { $courseCodeKey = ConvertTo-NormalizedKey $codeMatch.Value }
    $ranked = foreach ($file in $candidates) {
        $key = ConvertTo-NormalizedKey ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
        $score = 0
        if ($key -eq $packageKey) { $score += 100 }
        elseif ($packageKey -and $key.Contains($packageKey)) { $score += 70 }
        if ($courseCodeKey -and $key.Contains($courseCodeKey)) { $score += 60 }
        if ($key.Contains('courseworkbook')) { $score += 20 }
        [pscustomobject]@{ File = $file; Score = $score }
    }
    $bestScore = ($ranked | Measure-Object Score -Maximum).Maximum
    $best = @($ranked | Where-Object Score -eq $bestScore)
    if ($bestScore -gt 0 -and $best.Count -eq 1) { return $best[0].File.FullName }
    throw "The course workbook is ambiguous for $($Course.FileName). Use -Workbook with one of: $($candidates.Name -join ', ')"
}

function Write-DesignReviewContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$BaselinePath
    )
    if ($Artifact.Kind -ne 'xlsx') { throw 'The course workbook artifact must be an XLSX document.' }
    $normalized = Join-Path $RunPath ($Artifact.NormalizedXml.Replace('/', '\'))
    $document = Read-XmlFile $normalized
    $sheet = $document.SelectSingleNode('/Workbook/Sheet[translate(@name,"ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz")="design review"]')
    if ($null -eq $sheet) { throw "The required 'Design Review' tab was not found in $($Artifact.FileName)." }

    $cells = @{}
    foreach ($cell in $sheet.SelectNodes('./Cell')) {
        $valueNode = $cell.SelectSingleNode('./Value')
        $cells[$cell.GetAttribute('ref')] = if ($null -ne $valueNode) { [string]$valueNode.InnerText } else { '' }
    }
    $headerRow = 0; $statusColumn = ''; $reviewerColumns = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $cells.GetEnumerator()) {
        if ($entry.Value -eq 'Status' -and $entry.Key -match '^([A-Z]+)(\d+)$') { $statusColumn = $Matches[1]; $headerRow = [int]$Matches[2] }
    }
    if ($headerRow -eq 0 -or -not $statusColumn) { throw "The 'Design Review' tab has no recognizable Status header." }
    foreach ($entry in $cells.GetEnumerator()) {
        if ($entry.Key -match '^([A-Z]+)(\d+)$' -and [int]$Matches[2] -eq $headerRow -and $entry.Value -like 'Reviewer Notes*') { $reviewerColumns.Add($Matches[1]) }
    }

    $definitions = @(Get-CriterionDefinitions -Markdown ([System.IO.File]::ReadAllText($BaselinePath, [System.Text.Encoding]::UTF8)))
    $definitionById = @{}; foreach ($definition in $definitions) { $definitionById[$definition.Id] = $definition }
    $mapped = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $cells.GetEnumerator()) {
        if ($entry.Key -notmatch '^A(\d+)$') { continue }
        $row = [int]$Matches[1]; if ($row -le $headerRow) { continue }
        $raw = ([string]$entry.Value).Trim().TrimEnd('*')
        if ($raw -notmatch '^\d+\.\d+$') { continue }
        $id = $raw
        if (-not $definitionById.ContainsKey($id) -and $raw -match '^\d+\.\d$' -and $definitionById.ContainsKey("${raw}0")) { $id = "${raw}0" }
        if (-not $definitionById.ContainsKey($id)) { continue }
        $notes = foreach ($column in $reviewerColumns) {
            [pscustomobject][ordered]@{ Cell = "$column$row"; Header = $cells["$column$headerRow"]; Value = $cells["$column$row"] }
        }
        $mapped.Add([pscustomobject][ordered]@{
            Id = $id; Required = [bool]$definitionById[$id].Required; Row = $row
            MetricCell = "A$row"; CriteriaCell = "B$row"; Criteria = $cells["B$row"]
            StatusCell = "$statusColumn$row"; ExistingStatus = $cells["$statusColumn$row"]
            ExistingReviewerNotes = @($notes)
        })
    }
    $mappedIds = @($mapped | ForEach-Object Id)
    $contract = [pscustomobject][ordered]@{
        Workbook = $Artifact.FileName
        WorkbookSha256 = $Artifact.Sha256
        Sheet = 'Design Review'
        HeaderRow = $headerRow
        StatusColumn = $statusColumn
        ExistingReviewerNoteColumns = $reviewerColumns.ToArray()
        AutomatedReviewerNotesColumn = 'J'
        AutomatedReviewerNotesHeader = 'Automated Reviewer Notes'
        AllowedWorkbookStatuses = @('Verified','In Progress','Needs Attention','Exempt')
        StatusValidationPolicy = 'Normalize list validation on Design Review status cells to the four institutional statuses stated in the sheet instructions.'
        UnableToVerifyPolicy = 'Leave the workbook Status cell unchanged and record Unable to Verify in Automated Reviewer Notes and the Markdown audit.'
        CheckColumnPolicy = 'Preserve existing Check cells and formulas; they are a separate human/legacy workflow.'
        Criteria = @($mapped | Sort-Object Row)
        MissingBaselineCriteria = @($definitions | Where-Object { $_.Id -notin $mappedIds } | ForEach-Object Id)
    }
    $path = Join-Path $RunPath 'evidence\design_review_contract.json'
    Write-JsonFile $contract $path
    return [pscustomobject][ordered]@{ Path = Get-RelativeUnixPath $RunPath $path; Contract = $contract }
}

function Update-DesignReviewWorkbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Contract
    )
    $packageRoot = Join-Path $RunPath ($Artifact.PackageDirectory.Replace('/', '\'))
    $sheetPath = Get-WorkbookSheetPath -PackageRoot $packageRoot -SheetName $Contract.Sheet
    $sheet = Read-XmlFile $sheetPath
    Set-DesignReviewStatusValidation -Document $sheet -StatusColumn $Contract.StatusColumn
    $headerStyle = Get-CellStyle -Document $sheet -CellReference "G$($Contract.HeaderRow)"
    Set-WorksheetInlineString -Document $sheet -CellReference "$($Contract.AutomatedReviewerNotesColumn)$($Contract.HeaderRow)" -Value $Contract.AutomatedReviewerNotesHeader -Style $headerStyle

    $updated = New-Object System.Collections.Generic.List[string]
    $unmapped = New-Object System.Collections.Generic.List[string]
    foreach ($criterion in $Contract.Criteria) {
        $findingPath = Join-Path (Join-Path $RunPath 'findings') (Get-FindingFileName $criterion.Id)
        if (-not [System.IO.File]::Exists($findingPath)) { continue }
        $finding = Read-JsonFile $findingPath
        $status = [string](Get-WorkbookFindingField $finding @('status','Status'))
        if ($status -in @($Contract.AllowedWorkbookStatuses)) {
            $statusStyle = Get-CellStyle -Document $sheet -CellReference $criterion.StatusCell
            Set-WorksheetInlineString -Document $sheet -CellReference $criterion.StatusCell -Value $status -Style $statusStyle
        }
        $noteStyle = Get-CellStyle -Document $sheet -CellReference "G$($criterion.Row)"
        $note = ConvertTo-WorkbookReviewNote -Finding $finding
        Set-WorksheetInlineString -Document $sheet -CellReference "$($Contract.AutomatedReviewerNotesColumn)$($criterion.Row)" -Value $note -Style $noteStyle
        $updated.Add($criterion.Id)
    }
    foreach ($id in @($Contract.MissingBaselineCriteria)) { $unmapped.Add([string]$id) }
    Save-XmlDocument -Document $sheet -Path $sheetPath
    return [pscustomobject][ordered]@{
        Workbook = $Artifact.FileName; Sheet = $Contract.Sheet; UpdatedCriteria = $updated.ToArray()
        UnmappedCriteria = $unmapped.ToArray(); AutomatedNotesColumn = $Contract.AutomatedReviewerNotesColumn
    }
}

function Set-DesignReviewStatusValidation {
    param([xml]$Document, [string]$StatusColumn)
    foreach ($validation in $Document.SelectNodes("//*[local-name()='dataValidation' and @type='list']")) {
        $references = [string]$validation.GetAttribute('sqref')
        if ($references -notmatch "(^|\s)$StatusColumn\d+") { continue }
        $formula = $validation.SelectSingleNode("./*[local-name()='formula1']")
        if ($null -ne $formula) { $formula.InnerText = '"Needs Attention,In Progress,Verified,Exempt"' }
    }
}

function Get-WorkbookSheetPath {
    param([string]$PackageRoot, [string]$SheetName)
    $workbook = Read-XmlFile (Join-Path $PackageRoot 'xl\workbook.xml')
    $targetSheet = $workbook.SelectSingleNode("//*[local-name()='sheet' and @name='$SheetName']")
    if ($null -eq $targetSheet) { throw "Workbook sheet not found: $SheetName" }
    $relationId = $targetSheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $relationships = Read-XmlFile (Join-Path $PackageRoot 'xl\_rels\workbook.xml.rels')
    $relationship = $relationships.SelectSingleNode("//*[local-name()='Relationship' and @Id='$relationId']")
    if ($null -eq $relationship) { throw "Workbook relationship not found for sheet: $SheetName" }
    $target = $relationship.GetAttribute('Target').Replace('/', '\').TrimStart('\')
    if ($target.StartsWith('..\')) { $target = $target.Substring(3) }
    $path = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PackageRoot 'xl') $target))
    if (-not (Test-PathWithin $path $PackageRoot)) { throw "Workbook sheet path escapes its package: $path" }
    return $path
}

function Set-WorksheetInlineString {
    param([xml]$Document, [string]$CellReference, [AllowEmptyString()][string]$Value, [string]$Style)
    if ($CellReference -notmatch '^([A-Z]+)(\d+)$') { throw "Invalid cell reference: $CellReference" }
    $rowNumber = $Matches[2]; $namespace = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $row = $Document.SelectSingleNode("//*[local-name()='sheetData']/*[local-name()='row' and @r='$rowNumber']")
    if ($null -eq $row) { throw "Worksheet row not found for $CellReference" }
    $cell = $row.SelectSingleNode("./*[local-name()='c' and @r='$CellReference']")
    if ($null -eq $cell) {
        $cell = $Document.CreateElement('c', $namespace); $cell.SetAttribute('r', $CellReference)
        $newColumnIndex = ConvertFrom-ExcelColumnName $Matches[1]; $inserted = $false
        foreach ($existing in @($row.SelectNodes("./*[local-name()='c']"))) {
            if ($existing.GetAttribute('r') -match '^([A-Z]+)\d+$' -and (ConvertFrom-ExcelColumnName $Matches[1]) -gt $newColumnIndex) {
                [void]$row.InsertBefore($cell, $existing); $inserted = $true; break
            }
        }
        if (-not $inserted) { [void]$row.AppendChild($cell) }
    }
    if ($Style) { $cell.SetAttribute('s', $Style) }
    $cell.SetAttribute('t', 'inlineStr')
    while ($cell.HasChildNodes) { [void]$cell.RemoveChild($cell.FirstChild) }
    $inline = $Document.CreateElement('is', $namespace); $text = $Document.CreateElement('t', $namespace)
    $text.SetAttribute('space', 'http://www.w3.org/XML/1998/namespace', 'preserve'); $text.InnerText = $Value
    [void]$inline.AppendChild($text); [void]$cell.AppendChild($inline)
}

function ConvertFrom-ExcelColumnName {
    param([Parameter(Mandatory)][string]$Name)
    $value = 0
    foreach ($character in $Name.ToUpperInvariant().ToCharArray()) { $value = ($value * 26) + ([int]$character - [int][char]'A' + 1) }
    return $value
}

function Get-CellStyle {
    param([xml]$Document, [string]$CellReference)
    $cell = $Document.SelectSingleNode("//*[local-name()='c' and @r='$CellReference']")
    if ($null -ne $cell -and $cell.HasAttribute('s')) { return $cell.GetAttribute('s') }
    return ''
}

function Save-XmlDocument {
    param([xml]$Document, [string]$Path)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false); $settings.Indent = $false
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
}

function ConvertTo-WorkbookReviewNote {
    param($Finding)
    $status = [string](Get-WorkbookFindingField $Finding @('status','Status'))
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("Automated review: $status.")
    foreach ($pair in @(
        @{ Label = 'Evidence'; Names = @('evidence','Evidence') },
        @{ Label = 'Issues'; Names = @('issues','Issues') },
        @{ Label = 'Recommendations'; Names = @('recommendations','Recommendations') },
        @{ Label = 'Needs from requester'; Names = @('needs_from_requester','NeedsFromRequester') }
    )) {
        $values = @(@(Get-WorkbookFindingField $Finding $pair.Names) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($values.Count -gt 0) { $parts.Add("$($pair.Label): $($values -join ' | ')") }
    }
    return $parts -join "`n"
}

function Get-WorkbookFindingField {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) { $property = $Object.PSObject.Properties[$name]; if ($null -ne $property) { return $property.Value } }
    return $null
}

Export-ModuleMember -Function Resolve-CourseWorkbook, Write-DesignReviewContract, Update-DesignReviewWorkbook
