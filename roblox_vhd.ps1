# Roblox Sounds VHD Manager - improved
# - option 1: create+mount VHD, move sounds, create junction
# - option 2: remove junction, dismount VHD and delete file (robust, retries)
# - option 3: exit and close the PowerShell session

# CONFIG
$vhdPath     = "$env:ProgramData\roblox_sounds.vhdx"
$tempPath    = "$env:TEMP\Roblox\sounds"
$driveLetter = "S"
$newTarget   = "$driveLetter`:\sounds"
$vhdSizeGB   = 2
$label       = "RBXSounds"
$removeRetries = 12
$removeDelaySec = 1

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Try to open file exclusively to detect lock
function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

function Create-VHD {
    if (Test-Path $vhdPath) {
        Write-Host "[!] VHD already exists at $vhdPath"
        return
    }

    try {
        # Prefer New-VHD if available
        if (Get-Command -Name New-VHD -ErrorAction SilentlyContinue) {
            New-VHD -Path $vhdPath -SizeBytes ($vhdSizeGB * 1GB) -Fixed | Out-Null
            Mount-VHD -Path $vhdPath | Out-Null

            Start-Sleep -Milliseconds 300

            # get newly created RAW disk
            $disk = Get-Disk | Where-Object PartitionStyle -Eq 'RAW' | Sort-Object Number -Descending | Select-Object -First 1
            if (-not $disk) { throw "Failed to find newly created disk." }
            Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null
            $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null
        } else {
            # fallback to diskpart
            Write-Host "[*] New-VHD cmdlet not found - using diskpart fallback"
            $vhdSizeMB = $vhdSizeGB * 1024
            $dp = @"
create vdisk file="$vhdPath" maximum=$vhdSizeMB type=fixed
select vdisk file="$vhdPath"
attach vdisk
create partition primary
format fs=ntfs quick label=$label
assign letter=$driveLetter
exit
"@
            $dpFile = Join-Path $env:TEMP "roblox_vhd_dp.txt"
            $dp | Out-File -FilePath $dpFile -Encoding ASCII
            diskpart /s $dpFile | Out-Null
            Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
        }

        # create target folder on new drive
        New-Item -ItemType Directory -Path $newTarget -Force | Out-Null

        # move files if tempPath exists and is not already a junction
        if (Test-Path $tempPath) {
            $item = Get-Item $tempPath -ErrorAction SilentlyContinue
            if (-not ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
                Write-Host "[*] Copying files from $tempPath to $newTarget ..."
                Copy-Item -Path (Join-Path $tempPath '*') -Destination $newTarget -Recurse -Force
                Write-Host "[*] Removing original $tempPath ..."
                Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "[*] $tempPath is already a junction - skipping copy."
            }
        } else {
            # ensure parent exists for junction
            $parent = Split-Path -Parent $tempPath
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        }

        # create junction
        Write-Host "[*] Creating junction: $tempPath -> $newTarget"
        cmd /c mklink /J "$tempPath" "$newTarget" | Out-Null

        Write-Host "[+] VHD created and mounted as $driveLetter`: - junction created."
    } catch {
        Write-Host "[ERROR] Create-VHD failed: $($_.Exception.Message)"
    }
}

function Try-Dismount-VhdMultiple {
    param([string]$vhdFile)
    # Try Dismount-VHD (Hyper-V)
    try {
        if (Get-Command -Name Dismount-VHD -ErrorAction SilentlyContinue) {
            Dismount-VHD -Path $vhdFile -ErrorAction SilentlyContinue
        }
    } catch {}

    # Try Dismount-DiskImage (Image module)
    try {
        if (Get-Command -Name Dismount-DiskImage -ErrorAction SilentlyContinue) {
            Dismount-DiskImage -ImagePath $vhdFile -ErrorAction SilentlyContinue
        }
    } catch {}

    # Fallback diskpart detach
    try {
        $dp = @"
select vdisk file="$vhdFile"
detach vdisk
exit
"@
        $tmp = Join-Path $env:TEMP "roblox_vhd_detach.txt"
        $dp | Out-File -FilePath $tmp -Encoding ASCII
        diskpart /s $tmp | Out-Null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Remove-VHD {
    if (-not (Test-Path $vhdPath)) {
        Write-Host "[!] VHD file not found: $vhdPath"
        return
    }

    try {
        # Remove junction if present
        if (Test-Path $tempPath) {
            $it = Get-Item $tempPath -ErrorAction SilentlyContinue
            if ($it -and ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Write-Host "[*] Removing junction $tempPath ..."
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "[*] $tempPath exists but is not a junction - leaving it."
            }
        }

        # Attempt to dismount using multiple methods, then try removal with retries
        Write-Host "[*] Attempting to dismount VHD..."
        Try-Dismount-VhdMultiple -vhdFile $vhdPath

        # wait until file is unlocked or retry detaches
        $attempt = 0
        while ($attempt -lt $removeRetries) {
            if (-not (Test-FileLocked -Path $vhdPath)) {
                break
            }
            Start-Sleep -Seconds $removeDelaySec
            $attempt++
            # try dismount again every few attempts
            if ($attempt -eq 3 -or $attempt -eq 6) {
                Try-Dismount-VhdMultiple -vhdFile $vhdPath
            }
        }

        if (Test-FileLocked -Path $vhdPath) {
            Write-Host "[ERROR] VHD file still in use after attempts. Cannot delete: $vhdPath"
            Write-Host "Hint: close programs that may use the file (Explorer, antivirus, virtualization services) or reboot."
            return
        }

        # remove file
        Write-Host "[*] Deleting VHD file..."
        Remove-Item -Path $vhdPath -Force -ErrorAction Stop
        Write-Host "[+] VHD file removed."
    } catch {
        Write-Host "[ERROR] Remove-VHD failed: $($_.Exception.Message)"
    }
}

# Ensure the script runs elevated
if (-not (Test-IsAdmin)) {
    Write-Host "[*] Requesting elevation..."
    Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit 0
}

# MENU
while ($true) {
    Write-Host ""
    Write-Host "=== Roblox Sounds VHD Manager ==="
    Write-Host "1) Create and mount VHD"
    Write-Host "2) Remove VHD and junction"
    Write-Host "3) Exit (close terminal)"
    $choice = Read-Host "Choose (1-3)"

    switch ($choice) {
        "1" { Create-VHD }
        "2" { Remove-VHD }
        "3" { Exit 0 }  # EXIT the PowerShell process
        default { Write-Host "[!] Invalid choice" }
    }
}
