Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Expand-SafeArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination,
        [int]$MaxEntries = 25000,
        [long]$MaxUncompressedBytes = 2147483648
    )

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -gt $MaxEntries) { throw "Archive has $($archive.Entries.Count) entries; limit is $MaxEntries." }
        [long]$total = 0
        $pathOwners = @{}
        foreach ($entry in $archive.Entries) {
            $total += $entry.Length
            if ($total -gt $MaxUncompressedBytes) { throw "Archive expands beyond the $MaxUncompressedBytes-byte safety limit." }
            if ($entry.CompressedLength -gt 0 -and $entry.Length -gt 1000000 -and ($entry.Length / [double]$entry.CompressedLength) -gt 500) {
                throw "Archive entry has a suspicious compression ratio: $($entry.FullName)."
            }
            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixMode -eq 0xA000) { throw "Symbolic links are not allowed in archives: $($entry.FullName)." }
            if ($entry.FullName.StartsWith('/') -or $entry.FullName.StartsWith('\') -or $entry.FullName -match '^[A-Za-z]:') { throw "Unsafe absolute archive path: $($entry.FullName)." }
            $normalized = ConvertTo-SafeArchiveRelativePath $entry.FullName
            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destinationRoot, $normalized))
            if (-not $target.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Archive entry escapes its destination: $($entry.FullName)." }
            if ($pathOwners.ContainsKey($target) -and $pathOwners[$target] -ne $entry.FullName) { throw "Distinct archive paths map to the same Windows path: $($pathOwners[$target]) and $($entry.FullName)." }
            $pathOwners[$target] = $entry.FullName
            if ($entry.FullName.EndsWith('/')) {
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
            $input = $entry.Open()
            try {
                $output = New-Object System.IO.FileStream($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function ConvertTo-SafeArchiveRelativePath {
    param([Parameter(Mandatory)][string]$ArchivePath)
    $segments = $ArchivePath.Replace('\', '/').Split('/')
    $safeSegments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
        if ($segment -eq '') { continue }
        if ($segment -eq '.' -or $segment -eq '..') { $safeSegments.Add($segment); continue }
        $safe = [regex]::Replace($segment, '[<>:"|?*\x00-\x1F]', '_').TrimEnd('.', ' ')
        if ($safe -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') { $safe = '_' + $safe }
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = '_' }
        $safeSegments.Add($safe)
    }
    return ($safeSegments -join '\')
}

function Compress-DirectoryAsZip {
    param([Parameter(Mandatory)][string]$SourceDirectory, [Parameter(Mandatory)][string]$DestinationFile)
    if ([System.IO.File]::Exists($DestinationFile)) { [System.IO.File]::Delete($DestinationFile) }
    $sourceRoot = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
    $stream = New-Object System.IO.FileStream($DestinationFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($sourceRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
                $relative = $file.Substring($sourceRoot.Length).Replace('\', '/')
                $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
                $input = [System.IO.File]::OpenRead($file)
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

Export-ModuleMember -Function Expand-SafeArchive, Compress-DirectoryAsZip, ConvertTo-SafeArchiveRelativePath
