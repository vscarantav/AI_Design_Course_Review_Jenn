Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArchiveWorker.psm1') -Force

function Invoke-DeterministicChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$HtmlResults,
        [Parameter(Mandatory)][string]$ExtractedRoot,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )
    $graded = New-Object System.Collections.Generic.List[object]
    $manual = New-Object System.Collections.Generic.List[object]
    $noDueDate = New-Object System.Collections.Generic.List[string]
    $attemptViolations = New-Object System.Collections.Generic.List[string]
    $discussionDateMismatches = New-Object System.Collections.Generic.List[string]
    $weekStats = [ordered]@{}
    foreach ($item in @($Inventory.Items)) {
        $pointsText = Get-SettingValue $item 'points_possible'; $points = 0.0; [double]::TryParse($pointsText, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$points) | Out-Null
        $gradingType = Get-SettingValue $item 'grading_type'; $quizType = Get-SettingValue $item 'quiz_type'
        $isGraded = $points -gt 0 -and $gradingType -ne 'not_graded'
        if ($quizType -eq 'assignment') { $isGraded = $true }
        if (-not $isGraded) { continue }
        $graded.Add($item)
        $week = if ($item.Week) { [string]$item.Week } else { 'unknown' }
        if (-not $weekStats.Contains($week)) { $weekStats[$week] = [ordered]@{ GradedItems = 0; ManualItems = 0; DueWeekdays = @(); ItemsWithoutDueDate = 0 } }
        $weekStats[$week].GradedItems++
        $due = Get-SettingValue $item 'due_at'
        if ([string]::IsNullOrWhiteSpace($due)) { $noDueDate.Add("$($item.ModuleTitle) > $($item.Title)"); $weekStats[$week].ItemsWithoutDueDate++ }
        else { $date = [DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse($due, [ref]$date)) { $weekStats[$week].DueWeekdays += $date.DayOfWeek.ToString() } }
        $submission = Get-SettingValue $item 'submission_types'
        $questionTypes = @($item.QuestionTypes)
        $isManual = ($item.Type -eq 'Assignment' -and $submission -match 'online_upload|online_text_entry|online_url|media_recording|on_paper') -or
                    ($item.Type -match 'Discussion') -or
                    ($quizType -eq 'assignment' -and ($questionTypes -match 'essay_question|file_upload_question'))
        if ($isManual) {
            $manual.Add($item); $weekStats[$week].ManualItems++
            $attemptText = Get-SettingValue $item 'allowed_attempts'; $attempts = 0
            if ([int]::TryParse($attemptText, [ref]$attempts) -and ($attempts -lt 1 -or $attempts -gt 3)) { $attemptViolations.Add("$($item.Title): allowed_attempts=$attempts") }
        }
        if ($item.Type -match 'Discussion' -and $due) {
            $lock = Get-SettingValue $item 'lock_at'; if ($due -ne $lock) { $discussionDateMismatches.Add("$($item.Title): due_at=$due; lock_at=$lock") }
        }
    }
    foreach ($key in @($weekStats.Keys)) { $weekStats[$key].DueWeekdays = @($weekStats[$key].DueWeekdays | Sort-Object -Unique) }

    $accessibility = [ordered]@{
        HtmlDocuments = @($HtmlResults).Count
        Images = (@($HtmlResults | Measure-Object ImageCount -Sum).Sum)
        MissingOrBadAlt = (@($HtmlResults | Measure-Object MissingAltCount -Sum).Sum)
        HeadingOrderIssues = (@($HtmlResults | Measure-Object HeadingOrderIssueCount -Sum).Sum)
        TablesWithoutHeaders = (@($HtmlResults | Measure-Object TableWithoutHeaderCount -Sum).Sum)
        VagueLinks = (@($HtmlResults | Measure-Object VagueLinkCount -Sum).Sum)
        InlineColorDeclarations = (@($HtmlResults | Measure-Object InlineColorCount -Sum).Sum)
        LongSentences = (@($HtmlResults | Measure-Object LongSentenceCount -Sum).Sum)
    }
    $documents = @(Get-ChildItem -LiteralPath $ExtractedRoot -File -Recurse | Where-Object { $_.Extension -in @('.pdf','.docx','.xlsx','.pptx','.doc','.xls','.ppt') } | ForEach-Object { Get-RelativeUnixPath $ExtractedRoot $_.FullName })
    $largeMedia = @(Get-ChildItem -LiteralPath $ExtractedRoot -File -Recurse | Where-Object { $_.Extension -in @('.mp4','.mov','.m4v','.mp3','.wav') -and $_.Length -gt 25MB } | ForEach-Object { [pscustomobject]@{ Path = Get-RelativeUnixPath $ExtractedRoot $_.FullName; Bytes = $_.Length } })
    $moduleGates = @($Inventory.Modules | Where-Object { $_.UnlockAt -or $_.Prerequisites.Count -gt 0 -or $_.CompletionRequirements.Count -gt 0 } | ForEach-Object {
        [pscustomobject]@{ Module = $_.Title; UnlockAt = $_.UnlockAt; Prerequisites = $_.Prerequisites; CompletionRequirements = $_.CompletionRequirements }
    })
    $result = [pscustomobject][ordered]@{
        GradedItemCount = $graded.Count; ManuallyGradedItemCount = $manual.Count
        WeekStatistics = [pscustomobject]$weekStats
        GradedItemsWithoutDueDate = $noDueDate.ToArray()
        ManualItemsOutsideOneToThreeAttempts = $attemptViolations.ToArray()
        GradedDiscussionDueUntilMismatches = $discussionDateMismatches.ToArray()
        ModuleGates = $moduleGates
        AccessibilityTotals = [pscustomobject]$accessibility
        DocumentsRequiringManualAccessibilityReview = $documents
        LargeMediaOver25MB = $largeMedia
    }
    Write-JsonFile $result (Join-Path $EvidenceRoot 'deterministic_checks.json')
    return $result
}

function Get-SettingValue {
    param($Item, [string]$Name)
    $property = $Item.Settings.PSObject.Properties[$Name]
    if ($null -ne $property) { return [string]$property.Value }
    if ($Item.Settings -is [System.Collections.IDictionary] -and $Item.Settings.Contains($Name)) { return [string]$Item.Settings[$Name] }
    return $null
}

Export-ModuleMember -Function Invoke-DeterministicChecks
