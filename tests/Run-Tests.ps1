[CmdletBinding()]
param()

# Windows compatibility shim. The authoritative test suite is Python-native.
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$venvPython = Join-Path $repoRoot '.venv\Scripts\python.exe'
$python = $null
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
& $python -m unittest discover -s (Join-Path $repoRoot 'tests') -v
exit $LASTEXITCODE
