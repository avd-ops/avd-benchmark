# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
<#
.SYNOPSIS
    Windows PowerShell 5.1 guest helper for rpa-ui-responsiveness sandbox runs.
.DESCRIPTION
    Supports:
      - InitializeScratchRoot: creates %SystemDrive%\AvdBmTmp with explicit non-inherited
        Administrators/SYSTEM FullControl ACLs (Users denied) and a random per-SID subfolder.
      - VerifyManifest: verifies every file in manifest.sha256.json before execution.
      - CollectAndCleanup: reads fixed-shape numeric JSONL records from the session folder,
        writes a redacted session aggregate, deletes session scratch, and verifies empty root.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('InitializeScratchRoot', 'VerifyManifest', 'CollectAndCleanup')]
    [string]$Action,

    [Parameter()]
    [string]$InstallRoot = "$env:ProgramFiles\AvdBenchmark",

    [Parameter()]
    [string]$ScratchRoot = "$env:SystemDrive\AvdBmTmp",

    [Parameter()]
    [string]$UserSid,

    [Parameter()]
    [string]$SessionFolderName,

    [Parameter()]
    [string]$OutputAggregatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

switch ($Action) {
    'InitializeScratchRoot' {
        if ([string]::IsNullOrWhiteSpace($UserSid)) {
            throw 'UserSid is required for InitializeScratchRoot.'
        }
        if (-not (Test-Path -LiteralPath $ScratchRoot)) {
            New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
        }
        if (Test-ReparsePoint -Path $ScratchRoot) {
            throw 'ScratchRoot must not be a reparse point.'
        }
        $rootAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $rootAcl.SetAccessRuleProtection($true, $false)
        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propFlags = [System.Security.AccessControl.PropagationFlags]::None
        $rootAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', 'FullControl', $inheritFlags, $propFlags, 'Allow')))
        $rootAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', 'FullControl', $inheritFlags, $propFlags, 'Allow')))
        Set-Acl -LiteralPath $ScratchRoot -AclObject $rootAcl

        $folderName = [Guid]::NewGuid().ToString('N')
        $sessionPath = Join-Path $ScratchRoot $folderName
        New-Item -ItemType Directory -Path $sessionPath -Force | Out-Null
        $sidObj = New-Object System.Security.Principal.SecurityIdentifier($UserSid)
        $sessAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $sessAcl.SetAccessRuleProtection($true, $false)
        $sessAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', 'FullControl', $inheritFlags, $propFlags, 'Allow')))
        $sessAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', 'FullControl', $inheritFlags, $propFlags, 'Allow')))
        $sessAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidObj, 'Modify', $inheritFlags, $propFlags, 'Allow')))
        Set-Acl -LiteralPath $sessionPath -AclObject $sessAcl
        Write-Output $sessionPath
    }

    'VerifyManifest' {
        $manifestPath = Join-Path $InstallRoot 'manifest.sha256.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Manifest not found: $manifestPath"
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($entry in $manifest.files) {
            $target = Join-Path $InstallRoot $entry.path
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Test-ReparsePoint -Path $target)) {
                throw "Manifest file missing or reparse point: $($entry.path)"
            }
            $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $entry.sha256.ToLowerInvariant()) {
                throw "SHA-256 mismatch for $($entry.path)"
            }
        }
        Write-Output 'VERIFIED'
    }

    'CollectAndCleanup' {
        if ([string]::IsNullOrWhiteSpace($SessionFolderName) -or [string]::IsNullOrWhiteSpace($OutputAggregatePath)) {
            throw 'SessionFolderName and OutputAggregatePath are required.'
        }
        $sessionPath = Join-Path $ScratchRoot $SessionFolderName
        if (-not (Test-Path -LiteralPath $sessionPath) -or (Test-ReparsePoint -Path $sessionPath)) {
            throw 'Session scratch folder missing or reparse point.'
        }
        $logFile = Join-Path $sessionPath 'rpa-steps.jsonl'
        $records = @()
        if (Test-Path -LiteralPath $logFile -PathType Leaf) {
            if (Test-ReparsePoint -Path $logFile) { throw 'Log file cannot be a reparse point.' }
            $info = Get-Item -LiteralPath $logFile
            if ($info.Length -gt 10485760) { throw 'Log file exceeds 10 MiB cap.' }
            foreach ($line in (Get-Content -LiteralPath $logFile)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $obj = $line | ConvertFrom-Json
                $records += $obj
            }
        }
        @{
            attempted = $records.Count
            completed = @($records | Where-Object { $_.status -eq 'ok' }).Count
            timedOut  = @($records | Where-Object { $_.status -eq 'timeout' }).Count
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputAggregatePath -Encoding ascii

        Remove-Item -LiteralPath $sessionPath -Recurse -Force
        if (Test-Path -LiteralPath $sessionPath) {
            throw 'Failed to remove session scratch folder.'
        }
    }
}
