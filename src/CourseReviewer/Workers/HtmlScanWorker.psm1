Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force

function ConvertFrom-HtmlToText {
    param([AllowEmptyString()][string]$Html)
    if ($null -eq $Html) { return '' }
    $value = [regex]::Replace($Html, '<script\b.*?</script>|<style\b.*?</style>', ' ', 'IgnoreCase,Singleline')
    $value = [regex]::Replace($value, '</(?:p|div|li|h[1-6]|tr|section|article)>|<br\s*/?>', [Environment]::NewLine, 'IgnoreCase')
    $value = [regex]::Replace($value, '<[^>]+>', ' ', 'Singleline')
    $value = [System.Net.WebUtility]::HtmlDecode($value)
    $value = [regex]::Replace($value, '[ \t]+', ' ')
    $value = [regex]::Replace($value, '(?:\r?\n\s*){3,}', [Environment]::NewLine + [Environment]::NewLine)
    return $value.Trim()
}

function Invoke-HtmlScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtractedRoot, [Parameter(Mandatory)][string]$EvidenceRoot)
    $results = New-Object System.Collections.Generic.List[object]
    $textRoot = Join-Path $EvidenceRoot 'text'
    [System.IO.Directory]::CreateDirectory($textRoot) | Out-Null
    $usedNames = @{}
    $files = Get-ChildItem -LiteralPath $ExtractedRoot -File -Recurse | Where-Object { $_.Extension -in @('.html', '.htm') } | Sort-Object FullName
    foreach ($file in $files) {
        $html = [System.IO.File]::ReadAllText($file.FullName)
        $relative = Get-RelativeUnixPath $ExtractedRoot $file.FullName
        $text = ConvertFrom-HtmlToText $html
        $base = ConvertTo-SafeSlug $file.BaseName 45
        $textName = "$base.txt"; $suffix = 2
        while ($usedNames.ContainsKey($textName)) { $textName = "$base-$suffix.txt"; $suffix++ }
        $usedNames[$textName] = $true
        $textPath = Join-Path $textRoot $textName
        [System.IO.File]::WriteAllText($textPath, "SOURCE: $relative`r`n`r`n$text", (New-Object System.Text.UTF8Encoding($false)))

        $imageTags = @([regex]::Matches($html, '<img\b[^>]*>', 'IgnoreCase'))
        $missingAlt = @($imageTags | Where-Object { -not [regex]::IsMatch($_.Value, '\balt\s*=', 'IgnoreCase') -or [regex]::IsMatch($_.Value, '\balt\s*=\s*(["''])(?:\s*|[^"'']*\.(?:png|jpe?g|gif|svg))\1', 'IgnoreCase') }).Count
        $headingLevels = @([regex]::Matches($html, '<h([1-6])\b', 'IgnoreCase') | ForEach-Object { [int]$_.Groups[1].Value })
        $headingIssues = 0; for ($i = 1; $i -lt $headingLevels.Count; $i++) { if ($headingLevels[$i] -gt ($headingLevels[$i - 1] + 1)) { $headingIssues++ } }
        $tableBlocks = @([regex]::Matches($html, '<table\b.*?</table>', 'IgnoreCase,Singleline'))
        $tablesWithoutHeaders = @($tableBlocks | Where-Object { -not [regex]::IsMatch($_.Value, '<th\b', 'IgnoreCase') }).Count
        $vagueLinks = 0
        foreach ($link in [regex]::Matches($html, '<a\b[^>]*>(.*?)</a>', 'IgnoreCase,Singleline')) {
            if ((ConvertFrom-HtmlToText $link.Groups[1].Value) -match '^(click here|here|link|read more|more)$') { $vagueLinks++ }
        }
        $urls = @([regex]::Matches([System.Net.WebUtility]::HtmlDecode($html), 'https?://[^\s<>"'']+', 'IgnoreCase') | ForEach-Object { $_.Value.TrimEnd('.', ',', ')', ']', '"', "'") } | Sort-Object -Unique)
        $internalRefs = @([regex]::Matches($html, '(?:\$IMS-CC-FILEBASE\$|\$CANVAS_OBJECT_REFERENCE\$|\$WIKI_REFERENCE\$)[^"''<>\s]*', 'IgnoreCase') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $words = @([regex]::Matches($text, '\b[\p{L}\p{N}][\p{L}\p{N}''-]*\b')).Count
        $sentences = @([regex]::Matches($text, '[^.!?]+[.!?]+|[^.!?]+$') | Where-Object { [regex]::Matches($_.Value, '\b[\p{L}\p{N}]+\b').Count -gt 0 })
        $longSentences = @($sentences | Where-Object { [regex]::Matches($_.Value, '\b[\p{L}\p{N}]+\b').Count -gt 25 }).Count
        $syllables = 0
        foreach ($word in [regex]::Matches($text.ToLowerInvariant(), '\b[a-z]+\b')) {
            $count = [regex]::Matches($word.Value, '[aeiouy]+').Count
            if ($word.Value.EndsWith('e') -and $count -gt 1) { $count-- }
            $syllables += [Math]::Max(1, $count)
        }
        $grade = $null
        if ($words -gt 0 -and $sentences.Count -gt 0) { $grade = [Math]::Round(0.39 * ($words / [double]$sentences.Count) + 11.8 * ($syllables / [double]$words) - 15.59, 1) }
        $inlineColors = [regex]::Matches($html, '(?:color|background-color)\s*:', 'IgnoreCase').Count
        $issues = New-Object System.Collections.Generic.List[string]
        if ($missingAlt -gt 0) { $issues.Add("$missingAlt image(s) have missing or unhelpful alt text.") }
        if ($headingIssues -gt 0) { $issues.Add("$headingIssues heading-level jump(s) detected.") }
        if ($tablesWithoutHeaders -gt 0) { $issues.Add("$tablesWithoutHeaders table(s) contain no header cells.") }
        if ($vagueLinks -gt 0) { $issues.Add("$vagueLinks link(s) use vague text such as 'click here'.") }
        if ($inlineColors -gt 0) { $issues.Add("$inlineColors inline color declaration(s) require contrast/manual review.") }
        $results.Add([pscustomobject][ordered]@{
            Path = $relative; WordCount = $words; ImageCount = $imageTags.Count; MissingAltCount = $missingAlt
            HeadingCount = $headingLevels.Count; HeadingOrderIssueCount = $headingIssues; TableCount = $tableBlocks.Count
            TableWithoutHeaderCount = $tablesWithoutHeaders; VagueLinkCount = $vagueLinks; InlineColorCount = $inlineColors
            LongSentenceCount = $longSentences; FleschKincaidGrade = $grade; ExternalUrls = $urls; InternalReferences = $internalRefs
            Issues = $issues.ToArray(); TextFile = Get-RelativeUnixPath $EvidenceRoot $textPath
        })
    }
    Write-JsonFile ($results.ToArray()) (Join-Path $EvidenceRoot 'html_analysis.json')
    return $results.ToArray()
}

Export-ModuleMember -Function Invoke-HtmlScan, ConvertFrom-HtmlToText
