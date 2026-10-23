Set-StrictMode -Version Latest

function Write-JsonFile {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Read-XmlFile {
    param([Parameter(Mandatory)][string]$Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 100000000
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        return $document
    }
    finally { $reader.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function ConvertTo-SafeSlug {
    param([Parameter(Mandatory)][string]$Value, [int]$MaxLength = 60)
    $slug = ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if ($slug.Length -gt $MaxLength) { $slug = $slug.Substring(0, $MaxLength).TrimEnd('-') }
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'item' }
    return $slug
}

function ConvertTo-NormalizedKey {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    return [regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '')
}

function Get-RelativeUnixPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $rootUri = New-Object System.Uri(([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = New-Object System.Uri([System.IO.Path]::GetFullPath($Path))
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-UniqueDirectory {
    param([Parameter(Mandatory)][string]$DesiredPath)
    $candidate = $DesiredPath
    $suffix = 2
    while ([System.IO.Directory]::Exists($candidate)) {
        $candidate = "$DesiredPath-$suffix"
        $suffix++
    }
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    return $candidate
}

Export-ModuleMember -Function Write-JsonFile, Read-JsonFile, Read-XmlFile, Get-FileSha256, ConvertTo-SafeSlug, ConvertTo-NormalizedKey, Get-RelativeUnixPath, Test-PathWithin, Get-UniqueDirectory
