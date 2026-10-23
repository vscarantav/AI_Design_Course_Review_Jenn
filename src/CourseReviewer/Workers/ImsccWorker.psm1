Set-StrictMode -Version Latest
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HtmlScanWorker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArchiveWorker.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-CourseIdentityFromPackage {
    param([Parameter(Mandatory)][string]$PackagePath)
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
        try {
            $entry = $archive.GetEntry('course_settings/course_settings.xml')
            if ($null -eq $entry) { return [pscustomobject]@{ Title = $null; CourseCode = $null } }
            $stream = $entry.Open()
            try {
                $settings = New-Object System.Xml.XmlReaderSettings
                $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $reader = [System.Xml.XmlReader]::Create($stream, $settings)
                try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.Load($reader) } finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
            return [pscustomobject]@{ Title = Get-DirectChildValue $doc.DocumentElement 'title'; CourseCode = Get-DirectChildValue $doc.DocumentElement 'course_code' }
        }
        finally { $archive.Dispose() }
    }
    catch { return [pscustomobject]@{ Title = $null; CourseCode = $null } }
}

function Invoke-ImsccInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtractedRoot, [Parameter(Mandatory)][string]$EvidenceRoot)
    $manifestPath = Join-Path $ExtractedRoot 'imsmanifest.xml'
    if (-not [System.IO.File]::Exists($manifestPath)) { throw 'The package has no imsmanifest.xml.' }
    $manifest = Read-XmlFile $manifestPath
    $resources = New-Object System.Collections.Generic.List[object]
    $resourceMap = @{}
    foreach ($resourceNode in $manifest.SelectNodes("//*[local-name()='resource']")) {
        $files = @($resourceNode.SelectNodes("./*[local-name()='file']") | ForEach-Object { $_.GetAttribute('href') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $resource = [pscustomobject][ordered]@{ Identifier = $resourceNode.GetAttribute('identifier'); Type = $resourceNode.GetAttribute('type'); Href = $resourceNode.GetAttribute('href'); Files = $files }
        if (-not [string]::IsNullOrWhiteSpace($resource.Identifier)) { $resources.Add($resource); $resourceMap[$resource.Identifier] = $resource }
    }

    $summary = [ordered]@{
        Title = $null; CourseCode = $null; DefaultView = $null; ResourceCount = $resources.Count; ModuleCount = 0; ItemCount = 0; PublishedItemCount = 0
        Weeks = @(); ItemTypes = [ordered]@{}; CourseSettings = [ordered]@{}; PolicySettings = [ordered]@{}
        ExternalDomains = @(); InstructorFacingDocuments = @(); MissingReferencedFiles = @(); RubricCount = 0; OrphanRubrics = @()
    }
    $settingsPath = Join-Path $ExtractedRoot 'course_settings\course_settings.xml'
    if ([System.IO.File]::Exists($settingsPath)) {
        $settingsDoc = Read-XmlFile $settingsPath
        $summary.Title = Get-DirectChildValue $settingsDoc.DocumentElement 'title'
        $summary.CourseCode = Get-DirectChildValue $settingsDoc.DocumentElement 'course_code'
        $summary.DefaultView = Get-DirectChildValue $settingsDoc.DocumentElement 'default_view'
        foreach ($child in $settingsDoc.DocumentElement.ChildNodes) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and -not $child.HasChildNodes -or ($child.ChildNodes.Count -eq 1 -and $child.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text)) {
                if ($child.InnerText.Length -le 10000) { $summary.CourseSettings[$child.LocalName] = $child.InnerText }
            }
        }
    }
    $settingsRoot = Join-Path $ExtractedRoot 'course_settings'
    foreach ($policyFile in @('late_policy.xml', 'assignment_groups.xml', 'grading_standards.xml', 'context.xml')) {
        $path = Join-Path $settingsRoot $policyFile
        if (-not [System.IO.File]::Exists($path)) { continue }
        try {
            $policy = Read-XmlFile $path
            foreach ($leaf in $policy.SelectNodes('//*[not(*) and normalize-space(text())]')) {
                $key = "$([System.IO.Path]::GetFileNameWithoutExtension($policyFile)).$($leaf.LocalName)"
                if (-not $summary.PolicySettings.Contains($key)) { $summary.PolicySettings[$key] = $leaf.InnerText.Trim() }
            }
        } catch { }
    }

    $modules = New-Object System.Collections.Generic.List[object]
    $items = New-Object System.Collections.Generic.List[object]
    $modulePath = Join-Path $ExtractedRoot 'course_settings\module_meta.xml'
    if ([System.IO.File]::Exists($modulePath)) {
        $moduleDoc = Read-XmlFile $modulePath
        foreach ($moduleNode in $moduleDoc.SelectNodes("//*[local-name()='module']")) {
            $moduleTitle = Get-DirectChildValue $moduleNode 'title'
            $moduleState = Get-DirectChildValue $moduleNode 'workflow_state'
            $modulePosition = ConvertTo-Int (Get-DirectChildValue $moduleNode 'position')
            $prerequisites = @($moduleNode.SelectNodes("./*[local-name()='prerequisites']/*[local-name()='prerequisite']") | ForEach-Object {
                "$($_.GetAttribute('type')): $(Get-DirectChildValue $_ 'title') $(Get-DirectChildValue $_ 'identifierref')".Trim()
            })
            $requirements = @($moduleNode.SelectNodes("./*[local-name()='completionRequirements']/*[local-name()='completionRequirement']") | ForEach-Object {
                $pairs = @($_.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element } | ForEach-Object { "$($_.LocalName)=$($_.InnerText)" })
                "$($_.GetAttribute('type')): $($pairs -join ', ')"
            })
            $module = [pscustomobject][ordered]@{
                Identifier = $moduleNode.GetAttribute('identifier'); Title = $moduleTitle; Position = $modulePosition; WorkflowState = $moduleState
                RequireSequentialProgress = (Get-DirectChildValue $moduleNode 'require_sequential_progress') -eq 'true'
                UnlockAt = Get-DirectChildValue $moduleNode 'unlock_at'; Prerequisites = $prerequisites; CompletionRequirements = $requirements
            }
            $modules.Add($module)
            foreach ($itemNode in $moduleNode.SelectNodes("./*[local-name()='items']/*[local-name()='item']")) {
                $title = Get-DirectChildValue $itemNode 'title'; $itemState = Get-DirectChildValue $itemNode 'workflow_state'
                $published = $moduleState -eq 'active' -and $itemState -eq 'active'
                $identifierRef = Get-DirectChildValue $itemNode 'identifierref'; $resource = $null
                if ($identifierRef -and $resourceMap.ContainsKey($identifierRef)) { $resource = $resourceMap[$identifierRef] }
                $resourceType = $null; $resourceHref = $null
                if ($null -ne $resource) { $resourceType = $resource.Type; $resourceHref = $resource.Href }
                $item = [pscustomobject][ordered]@{
                    Identifier = $itemNode.GetAttribute('identifier'); IdentifierRef = $identifierRef; ModuleIdentifier = $module.Identifier
                    ModuleTitle = $moduleTitle; ModulePosition = $modulePosition; Position = ConvertTo-Int (Get-DirectChildValue $itemNode 'position')
                    Week = Get-WeekNumber "$moduleTitle $title"; Type = Get-DirectChildValue $itemNode 'content_type'; Title = $title
                    WorkflowState = $itemState; Published = $published; StudentFacing = ($published -and -not (Test-InstructorFacing "$moduleTitle $title"))
                    ResourceType = $resourceType; ResourceHref = $resourceHref; Url = Get-DirectChildValue $itemNode 'url'
                    Settings = [ordered]@{}; ExternalUrls = @(); QuestionTypes = @()
                }
                Add-ItemDetails -Item $item -Resource $resource -ExtractedRoot $ExtractedRoot
                $items.Add($item)
            }
        }
    }
    $sortedModules = @($modules | Sort-Object Position)
    $sortedItems = @($items | Sort-Object ModulePosition, Position)
    $summary.ModuleCount = $sortedModules.Count; $summary.ItemCount = $sortedItems.Count; $summary.PublishedItemCount = @($sortedItems | Where-Object Published).Count
    $summary.Weeks = @($sortedItems | ForEach-Object Week | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($group in $sortedItems | Group-Object Type | Sort-Object Name) { $summary.ItemTypes[$group.Name] = $group.Count }
    $summary.InstructorFacingDocuments = @($sortedItems | Where-Object { Test-InstructorFacing "$($_.ModuleTitle) $($_.Title)" } | ForEach-Object { "$($_.ModuleTitle) / $($_.Title)" } | Sort-Object -Unique)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($resource in $resources) { foreach ($file in $resource.Files) { if (-not [System.IO.File]::Exists((Resolve-PackagePath $ExtractedRoot $file))) { $missing.Add($file) } } }
    $summary.MissingReferencedFiles = @($missing | Sort-Object -Unique)
    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($item in $sortedItems) {
        foreach ($url in @($item.Url) + @($item.ExternalUrls)) {
            $uri = $null; if ([System.Uri]::TryCreate([string]$url, [System.UriKind]::Absolute, [ref]$uri)) { $domains.Add($uri.Host.ToLowerInvariant()) }
        }
    }
    $summary.ExternalDomains = @($domains | Sort-Object -Unique)
    $rubrics = @(Get-RubricInventory -ExtractedRoot $ExtractedRoot)
    $rubricReferences = @($sortedItems | ForEach-Object { if ($_.Settings.Contains('rubric_identifierref')) { $_.Settings['rubric_identifierref'] } } | Where-Object { $_ } | Sort-Object -Unique)
    $summary.RubricCount = $rubrics.Count
    $summary.OrphanRubrics = @($rubrics | Where-Object { $_.Identifier -notin $rubricReferences } | ForEach-Object { "$($_.Identifier): $($_.Title)" })
    Write-JsonFile ([pscustomobject]$summary) (Join-Path $EvidenceRoot 'course_summary.json')
    Write-JsonFile $sortedModules (Join-Path $EvidenceRoot 'modules.json')
    Write-JsonFile $sortedItems (Join-Path $EvidenceRoot 'items.json')
    Write-JsonFile ($resources.ToArray()) (Join-Path $EvidenceRoot 'resources.json')
    Write-JsonFile $rubrics (Join-Path $EvidenceRoot 'rubrics.json')
    Export-XmlEvidenceText -ExtractedRoot $ExtractedRoot -EvidenceRoot $EvidenceRoot
    Write-CourseDigest -Summary ([pscustomobject]$summary) -Modules $sortedModules -Items $sortedItems -Path (Join-Path $EvidenceRoot 'course_digest.md')
    return [pscustomobject]@{ Summary = [pscustomobject]$summary; Modules = $sortedModules; Items = $sortedItems; Resources = $resources.ToArray() }
}

function Add-ItemDetails {
    param($Item, $Resource, [string]$ExtractedRoot)
    if ($null -eq $Resource) { return }
    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $relativeFiles = @($Resource.Href) + @($Resource.Files) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($relative in $relativeFiles) {
        $path = Resolve-PackagePath $ExtractedRoot $relative
        if (-not $candidatePaths.Contains($path)) { $candidatePaths.Add($path) }
        if ([System.IO.File]::Exists($path)) {
            $parent = [System.IO.Path]::GetDirectoryName($path)
            if ($parent -and $parent -ne [System.IO.Path]::GetFullPath($ExtractedRoot)) {
                foreach ($sibling in [System.IO.Directory]::EnumerateFiles($parent)) { if (-not $candidatePaths.Contains($sibling)) { $candidatePaths.Add($sibling) } }
            }
        }
    }
    if ($Item.Type -match 'Discussion') {
        $topicIds = New-Object System.Collections.Generic.List[string]
        if ($Item.IdentifierRef) { $topicIds.Add([string]$Item.IdentifierRef) }
        foreach ($path in $candidatePaths.ToArray()) {
            if (-not [System.IO.File]::Exists($path) -or [System.IO.Path]::GetExtension($path) -ne '.xml') { continue }
            try { $topicDoc = Read-XmlFile $path; foreach ($node in $topicDoc.SelectNodes("//*[local-name()='topic_id']")) { if ($node.InnerText) { $topicIds.Add($node.InnerText.Trim()) } } } catch { }
        }
        foreach ($rootXml in [System.IO.Directory]::EnumerateFiles($ExtractedRoot, '*.xml', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if ($candidatePaths.Contains($rootXml)) { continue }
            try {
                $raw = [System.IO.File]::ReadAllText($rootXml)
                foreach ($topicId in $topicIds) { if ($raw.Contains("<$topicId") -or $raw.Contains(">$topicId<")) { $candidatePaths.Add($rootXml); break } }
            } catch { }
        }
    }
    $settingNames = @('points_possible','grading_type','submission_types','allowed_extensions','allowed_attempts','due_at','lock_at','unlock_at','quiz_type','group_category_id','workflow_state','assignment_group_identifier_ref','rubric_identifierref','rubric_use_for_grading','show_correct_answers','hide_correct_answers_at')
    $urls = New-Object System.Collections.Generic.List[string]; $questionTypes = New-Object System.Collections.Generic.List[string]
    foreach ($path in $candidatePaths) {
        if (-not [System.IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 50000000) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($path)
            foreach ($match in [regex]::Matches([System.Net.WebUtility]::HtmlDecode($content), 'https?://[^\s<>"'']+', 'IgnoreCase')) { $urls.Add($match.Value.TrimEnd('.', ',', ')', ']', '"', "'")) }
            if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.xml','.qti')) { continue }
            $doc = Read-XmlFile $path
            foreach ($name in $settingNames) {
                $node = $doc.SelectSingleNode("//*[local-name()='$name']")
                if ($null -ne $node -and -not [string]::IsNullOrWhiteSpace($node.InnerText) -and -not $Item.Settings.Contains($name)) { $Item.Settings[$name] = $node.InnerText.Trim() }
            }
            foreach ($node in $doc.SelectNodes("//*[local-name()='question_type']")) { if ($node.InnerText) { $questionTypes.Add($node.InnerText.Trim()) } }
            foreach ($label in $doc.SelectNodes("//*[local-name()='fieldlabel' and text()='question_type']")) {
                $value = $label.ParentNode.SelectSingleNode(".//*[local-name()='value']"); if ($null -ne $value) { $questionTypes.Add($value.InnerText.Trim()) }
            }
        } catch { }
    }
    $Item.ExternalUrls = @($urls | Sort-Object -Unique); $Item.QuestionTypes = @($questionTypes | Sort-Object -Unique)
}

function Get-RubricInventory {
    param([string]$ExtractedRoot)
    $path = Join-Path $ExtractedRoot 'course_settings\rubrics.xml'
    if (-not [System.IO.File]::Exists($path)) { return @() }
    $doc = Read-XmlFile $path
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($rubricNode in $doc.SelectNodes("//*[local-name()='rubric']")) {
        $criteria = New-Object System.Collections.Generic.List[object]
        foreach ($criterionNode in $rubricNode.SelectNodes("./*[local-name()='criteria']/*[local-name()='criterion']")) {
            $ratings = @($criterionNode.SelectNodes("./*[local-name()='ratings']/*[local-name()='rating']") | ForEach-Object {
                [pscustomobject][ordered]@{ Description = Get-DirectChildValue $_ 'description'; Points = Get-DirectChildValue $_ 'points'; LongDescription = Get-DirectChildValue $_ 'long_description' }
            })
            $criteria.Add([pscustomobject][ordered]@{
                Id = Get-DirectChildValue $criterionNode 'criterion_id'; Description = Get-DirectChildValue $criterionNode 'description'
                Points = Get-DirectChildValue $criterionNode 'points'; RatingCount = $ratings.Count; Ratings = $ratings
            })
        }
        $result.Add([pscustomobject][ordered]@{
            Identifier = $rubricNode.GetAttribute('identifier'); Title = Get-DirectChildValue $rubricNode 'title'; PointsPossible = Get-DirectChildValue $rubricNode 'points_possible'
            CriterionCount = $criteria.Count; LevelsPerCriterion = @($criteria | ForEach-Object RatingCount); AllCriteriaBinary = (@($criteria | Where-Object RatingCount -ne 2).Count -eq 0)
            Criteria = $criteria.ToArray()
        })
    }
    return $result.ToArray()
}

function Export-XmlEvidenceText {
    param([string]$ExtractedRoot, [string]$EvidenceRoot)
    $outputRoot = Join-Path $EvidenceRoot 'xml_text'; [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $index = New-Object System.Collections.Generic.List[object]; $used = @{}
    $files = Get-ChildItem -LiteralPath $ExtractedRoot -File -Recurse | Where-Object { $_.Extension -in @('.xml','.qti') -and $_.Length -le 50000000 }
    foreach ($file in $files) {
        try {
            $doc = Read-XmlFile $file.FullName
            $chunks = @($doc.SelectNodes("//*[local-name()='text' or local-name()='description' or local-name()='message' or local-name()='question_text' or local-name()='body' or local-name()='title' or local-name()='display_name']") |
                Where-Object { -not $_.ParentNode.LocalName -in @('text','description','message','question_text','body') } |
                ForEach-Object { ConvertFrom-HtmlToText ([System.Net.WebUtility]::HtmlDecode($_.InnerText)) } | Where-Object { $_ } | Select-Object -Unique)
            if ($chunks.Count -eq 0) { continue }
            $relative = Get-RelativeUnixPath $ExtractedRoot $file.FullName; $base = ConvertTo-SafeSlug $file.BaseName 42; $name = "$base.txt"; $suffix = 2
            while ($used.ContainsKey($name)) { $name = "$base-$suffix.txt"; $suffix++ }; $used[$name] = $true
            $out = Join-Path $outputRoot $name
            [System.IO.File]::WriteAllText($out, "SOURCE: $relative`r`n`r`n$($chunks -join "`r`n`r`n")", (New-Object System.Text.UTF8Encoding($false)))
            $index.Add([pscustomobject]@{ Source = $relative; TextFile = Get-RelativeUnixPath $EvidenceRoot $out; Chunks = $chunks.Count })
        } catch { }
    }
    Write-JsonFile ($index.ToArray()) (Join-Path $EvidenceRoot 'xml_text_index.json')
}

function Write-CourseDigest {
    param($Summary, $Modules, $Items, [string]$Path)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Deterministic course digest'); $lines.Add(''); $lines.Add("- Title: $($Summary.Title)"); $lines.Add("- Code: $($Summary.CourseCode)")
    $lines.Add("- Modules/items/published items: $($Summary.ModuleCount)/$($Summary.ItemCount)/$($Summary.PublishedItemCount)")
    $lines.Add("- Weeks detected: $($Summary.Weeks -join ', ')"); $lines.Add("- Home view: $($Summary.DefaultView)"); $lines.Add("- External domains: $($Summary.ExternalDomains -join ', ')")
    $lines.Add(''); $lines.Add('## Modules'); $lines.Add('')
    foreach ($module in $Modules) { $lines.Add("- $($module.Position). $($module.Title) [$($module.WorkflowState)] sequential=$($module.RequireSequentialProgress) unlock=$($module.UnlockAt); prerequisites=$($module.Prerequisites -join ' | ')") }
    $lines.Add(''); $lines.Add('## Items'); $lines.Add('')
    foreach ($item in $Items) { $pairs = @($item.Settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }); $lines.Add("- $($item.ModuleTitle) > $($item.Title) | $($item.Type) | published=$($item.Published) | href=$($item.ResourceHref) | $($pairs -join '; ')") }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-DirectChildValue { param($Node, [string]$Name); $child = $Node.SelectSingleNode("./*[local-name()='$Name']"); if ($null -eq $child) { return $null }; return $child.InnerText.Trim() }
function ConvertTo-Int { param($Value); $number = 0; if ([int]::TryParse([string]$Value, [ref]$number)) { return $number }; return 0 }
function Get-WeekNumber { param([string]$Value); $match = [regex]::Match($Value, '(?:week|w)\s*0?(\d{1,2})', 'IgnoreCase'); if ($match.Success) { return ([int]$match.Groups[1].Value).ToString('00') }; return $null }
function Test-InstructorFacing { param([string]$Value); return [regex]::IsMatch($Value, 'instructor|teaching notes|setup notes|grader|do not publish|course resources', 'IgnoreCase') }
function Resolve-PackagePath { param([string]$Root, [string]$Relative); $decoded = [System.Uri]::UnescapeDataString(($Relative -split '[?#]')[0]).TrimStart('/', '\'); $clean = ConvertTo-SafeArchiveRelativePath $decoded; $path = [System.IO.Path]::GetFullPath((Join-Path $Root $clean)); if (Test-PathWithin $path $Root) { return $path }; return (Join-Path $Root '__invalid_reference__') }

Export-ModuleMember -Function Get-CourseIdentityFromPackage, Invoke-ImsccInventory
