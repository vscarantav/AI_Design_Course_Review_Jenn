Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArchiveWorker.psm1') -Force

function Expand-OfficeDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$OfficeRoot
    )
    $hash = Get-FileSha256 $SourcePath
    $id = "$(ConvertTo-SafeSlug ([System.IO.Path]::GetFileNameWithoutExtension($SourcePath)) 42)-$($hash.Substring(0,10))"
    $artifactRoot = Join-Path $OfficeRoot $id
    $packageRoot = Join-Path $artifactRoot 'package'
    [System.IO.Directory]::CreateDirectory($artifactRoot) | Out-Null
    Expand-SafeArchive -ArchivePath $SourcePath -Destination $packageRoot
    $normalizedPath = Join-Path $artifactRoot 'normalized.xml'
    $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    if ($extension -eq '.xlsx') { Write-NormalizedWorkbookXml -PackageRoot $packageRoot -OutputPath $normalizedPath }
    elseif ($extension -eq '.docx') { Write-NormalizedDocumentXml -PackageRoot $packageRoot -OutputPath $normalizedPath }
    else { throw "Unsupported Office document: $SourcePath" }
    $reviewFiles = @(Write-OfficeReviewViews -ArtifactRoot $artifactRoot -NormalizedPath $normalizedPath -Extension $extension -RunPath $RunPath)

    $artifact = [ordered]@{
        Id = $id
        SourcePath = [System.IO.Path]::GetFullPath($SourcePath)
        SourceRelativePath = if (Test-PathWithin $SourcePath $RunPath) { Get-RelativeUnixPath $RunPath $SourcePath } else { [System.IO.Path]::GetFileName($SourcePath) }
        FileName = [System.IO.Path]::GetFileName($SourcePath)
        Kind = $extension.TrimStart('.')
        Sha256 = $hash
        PackageDirectory = Get-RelativeUnixPath $RunPath $packageRoot
        NormalizedXml = Get-RelativeUnixPath $RunPath $normalizedPath
        ReviewFiles = $reviewFiles
        PackageEntryCount = @([System.IO.Directory]::EnumerateFiles($packageRoot, '*', [System.IO.SearchOption]::AllDirectories)).Count
    }
    Write-JsonFile $artifact (Join-Path $artifactRoot 'document.json')
    return [pscustomobject]$artifact
}

function Write-OfficeReviewViews {
    param([string]$ArtifactRoot, [string]$NormalizedPath, [string]$Extension, [string]$RunPath)
    $viewsRoot = Join-Path $ArtifactRoot 'views'
    [System.IO.Directory]::CreateDirectory($viewsRoot) | Out-Null
    $files = New-Object System.Collections.Generic.List[string]
    $index = New-Object System.Collections.Generic.List[object]
    $document = Read-XmlFile $NormalizedPath
    if ($Extension -eq '.xlsx') {
        $usedNames = @{}
        foreach ($sheet in $document.SelectNodes('/Workbook/Sheet')) {
            $state = $sheet.GetAttribute('state')
            if ($state -ne 'visible') { continue }
            $base = ConvertTo-SafeSlug $sheet.GetAttribute('name') 48
            $name = "$base.tsv"; $suffix = 2
            while ($usedNames.ContainsKey($name)) { $name = "$base-$suffix.tsv"; $suffix++ }
            $usedNames[$name] = $true
            $viewPath = Join-Path $viewsRoot $name
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add("Cell`tFormula`tValue")
            foreach ($cell in $sheet.SelectNodes('./Cell')) {
                $formulaNode = $cell.SelectSingleNode('./Formula'); $valueNode = $cell.SelectSingleNode('./Value')
                $formula = if ($null -ne $formulaNode) { ConvertTo-TsvField $formulaNode.InnerText } else { '' }
                $value = if ($null -ne $valueNode) { ConvertTo-TsvField $valueNode.InnerText } else { '' }
                $lines.Add("$($cell.GetAttribute('ref'))`t$formula`t$value")
            }
            [System.IO.File]::WriteAllLines($viewPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
            $relative = Get-RelativeUnixPath $RunPath $viewPath; $files.Add($relative)
            $index.Add([pscustomobject][ordered]@{ Sheet = $sheet.GetAttribute('name'); State = $state; CellCount = $sheet.SelectNodes('./Cell').Count; File = $relative })
        }
    }
    elseif ($Extension -eq '.docx') {
        $viewPath = Join-Path $viewsRoot 'document.txt'
        $lines = @($document.SelectNodes('/Document/Paragraph') | ForEach-Object { $_.InnerText })
        [System.IO.File]::WriteAllLines($viewPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
        $relative = Get-RelativeUnixPath $RunPath $viewPath; $files.Add($relative)
        $index.Add([pscustomobject][ordered]@{ Document = 'document'; ParagraphCount = $lines.Count; File = $relative })
    }
    Write-JsonFile ($index.ToArray()) (Join-Path $ArtifactRoot 'review_index.json')
    return $files.ToArray()
}

function ConvertTo-TsvField {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace("`t", ' ').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n')
}

function Restore-OfficeDocument {
    param([Parameter(Mandatory)]$Artifact, [Parameter(Mandatory)][string]$RunPath)
    $packageRoot = Join-Path $RunPath ($Artifact.PackageDirectory.Replace('/', '\'))
    if (-not [System.IO.File]::Exists((Join-Path $packageRoot '[Content_Types].xml'))) { throw "OOXML package is incomplete for $($Artifact.FileName)." }
    $outputRoot = Join-Path $RunPath 'output\rebuilt_office'
    [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $output = Join-Path $outputRoot $Artifact.FileName
    Compress-DirectoryAsZip -SourceDirectory $packageRoot -DestinationFile $output
    $check = [System.IO.Compression.ZipFile]::OpenRead($output)
    try { if ($null -eq $check.GetEntry('[Content_Types].xml')) { throw "Rebuilt Office package failed validation: $output" } }
    finally { $check.Dispose() }
    return $output
}

function Write-NormalizedDocumentXml {
    param([string]$PackageRoot, [string]$OutputPath)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    try {
        $writer.WriteStartDocument(); $writer.WriteStartElement('Document')
        $documentPath = Join-Path $PackageRoot 'word\document.xml'
        if ([System.IO.File]::Exists($documentPath)) {
            $doc = Read-XmlFile $documentPath
            $index = 0
            foreach ($paragraph in $doc.SelectNodes("//*[local-name()='p']")) {
                $parts = @($paragraph.SelectNodes(".//*[local-name()='t']") | ForEach-Object { $_.InnerText })
                $text = $parts -join ''
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $index++; $writer.WriteStartElement('Paragraph'); $writer.WriteAttributeString('index', [string]$index); $writer.WriteString($text); $writer.WriteEndElement()
                }
            }
        }
        $writer.WriteEndElement(); $writer.WriteEndDocument()
    }
    finally { $writer.Dispose() }
}

function Write-NormalizedWorkbookXml {
    param([string]$PackageRoot, [string]$OutputPath)
    $shared = New-Object System.Collections.Generic.List[string]
    $sharedPath = Join-Path $PackageRoot 'xl\sharedStrings.xml'
    if ([System.IO.File]::Exists($sharedPath)) {
        $sharedDoc = Read-XmlFile $sharedPath
        foreach ($si in $sharedDoc.SelectNodes("//*[local-name()='si']")) {
            $shared.Add((@($si.SelectNodes(".//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join ''))
        }
    }
    $relations = @{}
    $relsPath = Join-Path $PackageRoot 'xl\_rels\workbook.xml.rels'
    if ([System.IO.File]::Exists($relsPath)) {
        $relsDoc = Read-XmlFile $relsPath
        foreach ($rel in $relsDoc.SelectNodes("//*[local-name()='Relationship']")) { $relations[$rel.GetAttribute('Id')] = $rel.GetAttribute('Target') }
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true; $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    try {
        $writer.WriteStartDocument(); $writer.WriteStartElement('Workbook')
        $workbookPath = Join-Path $PackageRoot 'xl\workbook.xml'
        if ([System.IO.File]::Exists($workbookPath)) {
            $workbook = Read-XmlFile $workbookPath
            foreach ($sheet in $workbook.SelectNodes("//*[local-name()='sheet']")) {
                $writer.WriteStartElement('Sheet'); $writer.WriteAttributeString('name', $sheet.GetAttribute('name'))
                $state = $sheet.GetAttribute('state'); if ([string]::IsNullOrWhiteSpace($state)) { $state = 'visible' }; $writer.WriteAttributeString('state', $state)
                $relationId = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
                if ($relations.ContainsKey($relationId)) {
                    $target = ([string]$relations[$relationId]).Replace('/', '\').TrimStart('\')
                    if ($target.StartsWith('..\')) { $target = $target.Substring(3) }
                    $sheetPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PackageRoot 'xl') $target))
                    if ((Test-PathWithin $sheetPath $PackageRoot) -and [System.IO.File]::Exists($sheetPath)) {
                        $sheetDoc = Read-XmlFile $sheetPath
                        foreach ($cell in $sheetDoc.SelectNodes("//*[local-name()='c']")) {
                            $type = $cell.GetAttribute('t'); if ([string]::IsNullOrWhiteSpace($type)) { $type = 'n' }
                            $valueNode = $cell.SelectSingleNode("./*[local-name()='v']")
                            $value = if ($null -ne $valueNode) { $valueNode.InnerText } else { @($cell.SelectNodes(".//*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join '' }
                            $sharedIndex = 0
                            if ($type -eq 's' -and [int]::TryParse($value, [ref]$sharedIndex) -and $sharedIndex -ge 0 -and $sharedIndex -lt $shared.Count) { $value = $shared[$sharedIndex] }
                            $writer.WriteStartElement('Cell'); $writer.WriteAttributeString('ref', $cell.GetAttribute('r')); $writer.WriteAttributeString('type', $type)
                            $formula = $cell.SelectSingleNode("./*[local-name()='f']"); if ($null -ne $formula) { $writer.WriteElementString('Formula', $formula.InnerText) }
                            $writer.WriteElementString('Value', [string]$value); $writer.WriteEndElement()
                        }
                    }
                }
                $writer.WriteEndElement()
            }
        }
        $writer.WriteEndElement(); $writer.WriteEndDocument()
    }
    finally { $writer.Dispose() }
}

Export-ModuleMember -Function Expand-OfficeDocument, Restore-OfficeDocument
