[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'prepare', 'status', 'next', 'validate', 'finalize', 'rebuild-office', 'help')]
    [string]$Command = 'help',
    [Parameter(Position = 1)][string]$Target,
    [string]$Root = $PSScriptRoot,
    [string]$Workbook,
    [string]$Output
)

# Windows compatibility shim. The application itself is Python-native; use
# `python course_review.py ...` directly on either Windows or macOS.
$ErrorActionPreference = 'Stop'
$venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$python = $null
$prefix = @()
if (Test-Path -LiteralPath $venvPython) {
    $python = $venvPython
} else {
    $commandInfo = Get-Command python -ErrorAction SilentlyContinue
    if ($null -ne $commandInfo -and $commandInfo.Source -notlike '*\WindowsApps\python.exe') {
        $python = $commandInfo.Source
    } else {
        $installed = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe" -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($null -ne $installed) { $python = $installed.FullName }
    }
}
if (-not $python) { throw 'Python 3.10+ is required. Follow AGENTS.md to install it from the terminal.' }

if ($Command -eq 'help') {
    & $python (Join-Path $PSScriptRoot 'course_review.py') --help
    exit $LASTEXITCODE
}
$cliArguments = @((Join-Path $PSScriptRoot 'course_review.py'), $Command)
if ($Target) { $cliArguments += $Target }
if ($Root) { $cliArguments += @('--root', $Root) }
if ($Workbook) { $cliArguments += @('--workbook', $Workbook) }
if ($Output) { $cliArguments += @('--output', $Output) }
& $python @cliArguments
exit $LASTEXITCODE
