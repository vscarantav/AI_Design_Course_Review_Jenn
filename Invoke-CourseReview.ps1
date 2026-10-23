[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'prepare', 'status', 'next', 'validate', 'finalize', 'rebuild-office', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$Root = $PSScriptRoot,
    [string]$Workbook,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'src\CourseReviewer\Controller.psm1') -Force

switch ($Command) {
    'list' {
        Get-ReviewCourse -Root $Root | Format-Table FileName, CourseCode, Title -AutoSize
    }
    'prepare' {
        if ([string]::IsNullOrWhiteSpace($Target)) { throw 'prepare requires a course name, code, or .imscc path.' }
        Start-ReviewPreparation -Root $Root -Query $Target -WorkbookPath $Workbook -OutputPath $Output | ConvertTo-Json -Depth 20
    }
    'status' {
        Get-ReviewStatus -Root $Root -RunPath $Target
    }
    'next' {
        Get-NextReviewTask -Root $Root -RunPath $Target | ConvertTo-Json -Depth 20
    }
    'validate' {
        $result = Test-ReviewRun -Root $Root -RunPath $Target
        $result | ConvertTo-Json -Depth 20
        if (-not $result.IsValid) { exit 2 }
    }
    'finalize' {
        $result = Complete-ReviewRun -Root $Root -RunPath $Target
        $result | ConvertTo-Json -Depth 20
        if (-not $result.Validation.IsValid) { exit 2 }
    }
    'rebuild-office' {
        Restore-ReviewOfficeDocuments -Root $Root -RunPath $Target
    }
    default {
        @'
IMSCC Course Reviewer (local, no API)

  .\Invoke-CourseReview.ps1 list [-Root PATH]
  .\Invoke-CourseReview.ps1 prepare "COURSE X" [-Root PATH] [-Workbook COURSE.xlsx] [-Output PATH]
  .\Invoke-CourseReview.ps1 status [RUN_PATH]
  .\Invoke-CourseReview.ps1 next [RUN_PATH]
  .\Invoke-CourseReview.ps1 validate [RUN_PATH]
  .\Invoke-CourseReview.ps1 finalize [RUN_PATH]
  .\Invoke-CourseReview.ps1 rebuild-office [RUN_PATH]

When RUN_PATH is omitted, the newest run under .course-review\runs is used.
'@
    }
}
