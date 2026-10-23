Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PacketWorker.psm1') -Force

function Test-ReviewFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $criteriaPath = Join-Path $RunPath 'tasks\criteria.json'
    if (-not [System.IO.File]::Exists($criteriaPath)) { throw 'Run has no tasks\criteria.json.' }
    $criteria = @(Read-JsonFile $criteriaPath); $errors = New-Object System.Collections.Generic.List[string]; $warnings = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]; $statuses = @('Verified','In Progress','Needs Attention','Exempt','Unable to Verify'); $confidences = @('High','Medium','Low')
    foreach ($criterion in $criteria) {
        $path = Join-Path (Join-Path $RunPath 'findings') (Get-FindingFileName $criterion.Id)
        if (-not [System.IO.File]::Exists($path)) { $errors.Add("Missing finding for $($criterion.Id): $(Get-RelativeUnixPath $RunPath $path)"); continue }
        try {
            $rawFinding = Read-JsonFile $path
            $finding = [pscustomobject][ordered]@{
                CriterionId = Get-ObjectField $rawFinding @('criterion_id','CriterionId')
                CriterionTitle = Get-ObjectField $rawFinding @('criterion_title','CriterionTitle')
                Status = Get-ObjectField $rawFinding @('status','Status')
                Confidence = Get-ObjectField $rawFinding @('confidence','Confidence')
                Evidence = @(Get-ObjectField $rawFinding @('evidence','Evidence'))
                Issues = @(Get-ObjectField $rawFinding @('issues','Issues'))
                Recommendations = @(Get-ObjectField $rawFinding @('recommendations','Recommendations'))
                NeedsFromRequester = @(Get-ObjectField $rawFinding @('needs_from_requester','NeedsFromRequester'))
            }
        } catch { $errors.Add("Invalid finding file for $($criterion.Id): $($_.Exception.Message)"); continue }
        if ($finding.CriterionId -ne $criterion.Id) { $errors.Add("Finding $([System.IO.Path]::GetFileName($path)) says criterion_id '$($finding.CriterionId)', expected '$($criterion.Id)'.") }
        if ($finding.Status -notin $statuses) { $errors.Add("$($criterion.Id) has invalid status '$($finding.Status)'.") }
        if ($finding.Confidence -notin $confidences) { $errors.Add("$($criterion.Id) has invalid confidence '$($finding.Confidence)'.") }
        if ($finding.Status -eq 'Verified' -and @($finding.Evidence).Count -eq 0) { $errors.Add("$($criterion.Id) is Verified but cites no evidence.") }
        if ($finding.Status -notin @('Verified','Exempt') -and @($finding.Recommendations).Count -eq 0) { $errors.Add("$($criterion.Id) is $($finding.Status) but has no recommendation.") }
        if ($criterion.Required -and $finding.Status -notin @('Verified','Exempt')) { $warnings.Add("Priority finding: required criterion $($criterion.Id) is $($finding.Status).") }
        $findings.Add([pscustomobject]@{ Criterion = $criterion; Finding = $finding })
    }
    return [pscustomobject][ordered]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray(); Warnings = $warnings.ToArray(); ExpectedCriteria = $criteria.Count; CompletedCriteria = $findings.Count; Findings = $findings.ToArray() }
}

function Write-ReviewReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Validation)
    $summary = Read-JsonFile (Join-Path $RunPath 'evidence\course_summary.json')
    $output = Join-Path $RunPath 'output\course_review.md'; [System.IO.Directory]::CreateDirectory((Split-Path -Parent $output)) | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $display = if ($summary.CourseCode) { $summary.CourseCode } elseif ($summary.Title) { $summary.Title } else { [System.IO.Path]::GetFileNameWithoutExtension($Run.SourcePackage) }
    $lines.Add("# Course Review - $display"); $lines.Add(''); $lines.Add("- Course title: $($summary.Title)"); $lines.Add("- Course code: $($summary.CourseCode)")
    $lines.Add("- Source package: $([System.IO.Path]::GetFileName($Run.SourcePackage))"); $lines.Add("- Source SHA-256: ``$($Run.SourceSha256)``")
    if ($null -ne $Run.PSObject.Properties['SourceWorkbook']) { $lines.Add("- Course workbook: $([System.IO.Path]::GetFileName($Run.SourceWorkbook))"); $lines.Add("- Workbook SHA-256: ``$($Run.WorkbookSha256)``") }
    $lines.Add("- Review generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm zzz')"); $lines.Add("- Modules / items / published items: $($summary.ModuleCount) / $($summary.ItemCount) / $($summary.PublishedItemCount)")
    if ($null -ne $Run.PSObject.Properties['DesignReviewContract']) {
        $contractPath = Join-Path $RunPath ($Run.DesignReviewContract.Replace('/', '\'))
        if ([System.IO.File]::Exists($contractPath)) { $contract = Read-JsonFile $contractPath; $lines.Add("- Workbook scorecard mapping: $(@($contract.Criteria).Count) criteria mapped; $(@($contract.MissingBaselineCriteria).Count) retained in this audit only") }
    }
    $lines.Add(''); $lines.Add('Deterministic inventories are in `evidence/`; extracted source text is in `evidence/text/` and `evidence/xml_text/`.'); $lines.Add('')
    foreach ($group in $Validation.Findings | Group-Object { $_.Criterion.Category }) {
        $lines.Add("## $($group.Name)"); $lines.Add('')
        foreach ($pair in $group.Group) {
            $c = $pair.Criterion; $f = $pair.Finding; $required = if ($c.Required) { ' *' } else { '' }; $wwo = if ($c.Wwo) { ' [WWO]' } else { '' }
            $lines.Add("### $($c.Id) - $($c.Title)$required$wwo"); $lines.Add("Status: $($f.Status)  "); $lines.Add("Confidence: $($f.Confidence)")
            Add-MarkdownList $lines 'Evidence' @($f.Evidence); Add-MarkdownList $lines 'Issues' @($f.Issues); Add-MarkdownList $lines 'Recommendations' @($f.Recommendations); Add-MarkdownList $lines 'Needs from requester' @($f.NeedsFromRequester); $lines.Add('')
        }
    }
    foreach ($appendix in @('contradictions.md','not_reviewed.md','settings_and_assumptions.md','prior_review_comparison.md')) {
        $path = Join-Path (Join-Path $RunPath 'findings') $appendix
        if ([System.IO.File]::Exists($path)) { $lines.Add(''); $lines.Add([System.IO.File]::ReadAllText($path)); $lines.Add('') }
    }
    [System.IO.File]::WriteAllLines($output, $lines, (New-Object System.Text.UTF8Encoding($false)))
    return $output
}

function Add-MarkdownList { param($Lines, [string]$Label, $Values); $Lines.Add("${Label}:"); if (@($Values).Count -eq 0) { $Lines.Add('- None.') } else { foreach ($value in $Values) { $Lines.Add("- $value") } } }

function Get-ObjectField {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

Export-ModuleMember -Function Test-ReviewFindings, Write-ReviewReport
