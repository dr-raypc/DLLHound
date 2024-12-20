# DLLHound - DLL Sideloading Scanner
# Author: @ajm4n
# Description: Scans processes for potential DLL sideloading vulnerabilities
# Requires running with administrator privileges
#Requires -RunAsAdministrator

# ASCII art title
Write-Host @"
 _____  _      _      _    _                       _ 
|  __ \| |    | |    | |  | |                     | |
| |  | | |    | |    | |__| | ___  _   _ _ __   __| |
| |  | | |    | |    |  __  |/ _ \| | | | '_ \ / _  |
| |__| | |____| |____| |  | | (_) | |_| | | | | (_| |
|_____/|______|______|_|  |_|\___/ \__,_|_| |_|\__,_|
                        by @ajm4n
"@ -ForegroundColor Cyan

# Configuration
$VERY_SMALL_EXECUTABLE_SIZE = 50MB
$SMALL_EXECUTABLE_SIZE = 100MB
$STRICT_MAX_DLL_DEPENDENCIES = 10
$MAX_DLL_DEPENDENCIES = 50
$COMMON_SYSTEM_DLLS = @(
    'kernel32.dll', 'user32.dll', 'gdi32.dll', 'advapi32.dll', 'shell32.dll',
    'ole32.dll', 'oleaut32.dll', 'ntdll.dll', 'msvcrt.dll', 'ws2_32.dll'
)
$STANDARD_WINDOWS_PROCESSES = @(
    'explorer.exe', 'svchost.exe', 'lsass.exe', 'csrss.exe', 'wininit.exe',
    'services.exe', 'winlogon.exe', 'taskhostw.exe', 'spoolsv.exe', 'dwm.exe'
)

# Function to extract imported DLLs from a PE file
function Get-ImportedDLLs {
    param ([string]$FilePath)
    try {
        Write-Host "[INFO] Reading PE headers from ${FilePath}..." -ForegroundColor Cyan
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        $signature = [BitConverter]::ToUInt32($bytes, $peOffset)

        if ($signature -ne 0x4550) { 
            Write-Host "[WARNING] Invalid PE signature for ${FilePath}" -ForegroundColor Yellow
            return @() 
        }

        $optionalHeaderOffset = $peOffset + 24
        $importDirRvaOffset = $optionalHeaderOffset + 104
        $importDirRva = [BitConverter]::ToInt32($bytes, $importDirRvaOffset)
        $sectionOffset = $optionalHeaderOffset + 240
        $dlls = @()

        Write-Host "[INFO] Extracting imported DLLs from the PE header..." -ForegroundColor Cyan

        for ($i = 0; $i -lt 16; $i++) {
            $sectionStart = $sectionOffset + ($i * 40)
            if ($sectionStart + 40 -gt $bytes.Length) { break }

            $virtualAddress = [BitConverter]::ToInt32($bytes, $sectionStart + 12)
            $rawAddress = [BitConverter]::ToInt32($bytes, $sectionStart + 20)

            if ($importDirRva -ge $virtualAddress -and 
                $importDirRva -lt ($virtualAddress + [BitConverter]::ToInt32($bytes, $sectionStart + 8))) {

                $fileOffset = ($importDirRva - $virtualAddress) + $rawAddress

                while ($fileOffset -lt $bytes.Length - 20) {
                    $nameRva = [BitConverter]::ToInt32($bytes, $fileOffset + 12)
                    if ($nameRva -eq 0) { break }

                    $nameOffset = ($nameRva - $virtualAddress) + $rawAddress
                    $dllName = ""
                    $currentOffset = $nameOffset

                    while ($currentOffset -lt $bytes.Length) {
                        $byte = $bytes[$currentOffset]
                        if ($byte -eq 0) { break }
                        $dllName += [char]$byte
                        $currentOffset++
                    }

                    if ($dllName -match '\.dll$') {
                        Write-Host "[INFO] Found imported DLL: $dllName" -ForegroundColor Green
                        $dlls += $dllName
                    }

                    $fileOffset += 20 # Move to the next import descriptor
                }
                break
            }
        }

        return $dlls | Select-Object -Unique
    } catch {
        Write-Host "[ERROR] Error reading ${FilePath}: $_" -ForegroundColor Red
        return @()
    }
}

# Function to validate likely targets
function Test-IsLikelyTarget {
    param (
        [System.Diagnostics.Process]$Process,
        [switch]$StrictMode,
        [switch]$CustomMode,
        [int64]$CustomSize = 0,
        [int]$CustomDLLs = 0
    )
    try {
        Write-Host "[INFO] Analyzing process: $($Process.ProcessName) (PID: $($Process.Id))" -ForegroundColor Cyan
        $size = (Get-Item $Process.MainModule.FileName).Length
        $dllCount = $Process.Modules.Count
        $maxSize = if ($CustomMode) { $CustomSize } elseif ($StrictMode) { $VERY_SMALL_EXECUTABLE_SIZE } else { $SMALL_EXECUTABLE_SIZE }
        $maxDLLs = if ($CustomMode) { $CustomDLLs } elseif ($StrictMode) { $STRICT_MAX_DLL_DEPENDENCIES } else { $MAX_DLL_DEPENDENCIES }
        Write-Host "[INFO] Executable Size: $size bytes | Max Allowed: $maxSize bytes" -ForegroundColor DarkGray
        Write-Host "[INFO] DLL Count: $dllCount | Max Allowed: $maxDLLs" -ForegroundColor DarkGray
        return ($size -le $maxSize -and $dllCount -le $maxDLLs)
    } catch {
        Write-Host "[ERROR] Error analyzing $($Process.ProcessName): $_" -ForegroundColor Red
        return $false
    }
}

# Main scanning function
function Start-DLLSideloadingScan {
    param ([string]$ScanType = "Full", [int64]$CustomSize = 0, [int]$CustomDLLs = 0)
    Write-Host "[INFO] Starting DLL sideloading vulnerability scan..." -ForegroundColor Green
    Write-Host "[INFO] Scan Type: $ScanType" -ForegroundColor Cyan
    if ($ScanType -eq "Custom") {
        Write-Host "[INFO] Custom Settings: Max Size = $($CustomSize / 1MB)MB, Max DLLs = $CustomDLLs" -ForegroundColor Magenta
    }

    $results = @()
    $processes = Get-Process | Where-Object { $_.MainModule -and $STANDARD_WINDOWS_PROCESSES -notcontains $_.ProcessName }
    foreach ($process in $processes) {
        Write-Host "[INFO] Processing: $($process.ProcessName) (PID: $($process.Id))" -ForegroundColor Cyan
        if ($ScanType -ne "Full" -and -not (Test-IsLikelyTarget -Process $process -StrictMode:($ScanType -eq "Strict") -CustomMode:($ScanType -eq "Custom") -CustomSize $CustomSize -CustomDLLs $CustomDLLs)) {
            Write-Host "[INFO] Skipping process $($process.ProcessName) due to filter criteria." -ForegroundColor Yellow
            continue
        }
        try {
            $processPath = $process.MainModule.FileName
            Write-Host "[INFO] Analyzing process at $processPath..." -ForegroundColor Cyan
            $importedDLLs = Get-ImportedDLLs -FilePath $processPath
            $loadedDLLs = $process.Modules | Where-Object {
                $_.ModuleName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -ExpandProperty ModuleName

            $missingDLLs = $importedDLLs | Where-Object { $loadedDLLs -notcontains $_ }
            foreach ($dllName in $missingDLLs) {
                if ($COMMON_SYSTEM_DLLS -contains $dllName.ToLower()) {
                    Write-Host "[INFO] Skipping common system DLL: $dllName" -ForegroundColor Yellow
                    continue
                }
                Write-Host "[POTENTIAL] Potential DLL sideload found: $dllName" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    ProcessName = $process.ProcessName
                    ProcessId = $process.Id
                    ProcessPath = $processPath
                    MissingDLL = $dllName
                }
            }
        } catch {
            Write-Host "[ERROR] Error scanning process $($process.ProcessName): $_" -ForegroundColor Red
        }
    }

    # Output results
    if ($results.Count -gt 0) {
        Write-Host "[INFO] Vulnerable Programs Found:" -ForegroundColor Yellow
        $results | ForEach-Object {
            Write-Host "Process: $_.ProcessName (PID: $_.ProcessId)" -ForegroundColor Green
            Write-Host "Missing DLL: $_.MissingDLL" -ForegroundColor Red
        }

        # CSV Export Option
        $exportChoice = Read-Host "Do you want to export results to CSV? (y/n)"
        if ($exportChoice -eq "y") {
            $scanTime = Get-Date -Format 'yyyyMMdd_HHmmss'
            $exportPath = Join-Path $env:USERPROFILE "Desktop\DLLSideloadingScan_$ScanType_$scanTime.csv"
            $results | Export-Csv -Path $exportPath -NoTypeInformation
            Write-Host "[INFO] Results exported to: $exportPath" -ForegroundColor Green
        }
    } else {
        Write-Host "[INFO] No potential DLL sideloading vulnerabilities found." -ForegroundColor Green
    }
}

# User prompt
Write-Host "Select scan type:" -ForegroundColor Cyan
Write-Host "1: Full Scan (All Applications)"
Write-Host "2: Medium Scan (<100MB, <50 DLLs)"
Write-Host "3: Strict Scan (<50MB, <10 DLLs)"
Write-Host "4: Custom Scan (Define limits)"
$choice = Read-Host "Enter choice (1-4)"
switch ($choice) {
    "1" { Start-DLLSideloadingScan -ScanType "Full" }
    "2" { Start-DLLSideloadingScan -ScanType "Medium" }
    "3" { Start-DLLSideloadingScan -ScanType "Strict" }
    "4" { 
        $size = [int64](Read-Host "Max size (MB)") * 1MB
        $dlls = [int](Read-Host "Max DLLs")
        Start-DLLSideloadingScan -ScanType "Custom" -CustomSize $size -CustomDLLs $dlls
    }
    default { Write-Host "[INFO] Invalid choice. Running full scan." -ForegroundColor Yellow; Start-DLLSideloadingScan -ScanType "Full" }
}
