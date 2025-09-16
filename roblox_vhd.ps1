# === Roblox Sounds VHD Manager ===
# Файл для VHD
$vhdPath   = "$env:ProgramData\roblox_sounds.vhdx"
$tempPath  = "$env:TEMP\Roblox\sounds"
$newTarget = "S:\sounds"

function Create-VHD {
    if (Test-Path $vhdPath) {
        Write-Host "⚠️ VHD уже существует: $vhdPath"
        return
    }

    # Создание фиксированного VHDX на 2 ГБ
    New-VHD -Path $vhdPath -SizeBytes 2GB -Fixed | Out-Null
    Mount-VHD -Path $vhdPath | Out-Null

    # Инициализация
    $disk = Get-Disk | Where-Object PartitionStyle -Eq 'RAW' | Sort-Object Number -Descending | Select-Object -First 1
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null

    # Создание раздела
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter S
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "RBXSounds" -Confirm:$false | Out-Null

    # Создание папки для звуков
    New-Item -ItemType Directory -Path $newTarget -Force | Out-Null

    # Перенос содержимого если есть
    if (Test-Path $tempPath) {
        Copy-Item -Path "$tempPath\*" -Destination $newTarget -Recurse -Force
        Remove-Item $tempPath -Recurse -Force
    }

    # Junction
    cmd /c mklink /J "$tempPath" "$newTarget" | Out-Null

    Write-Host "✅ Диск S: создан, данные перенесены, симлинк настроен."
}

function Remove-VHD {
    # Удаление junction
    if (Test-Path $tempPath) {
        if ((Get-Item $tempPath).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-Item $tempPath -Force
            Write-Host "🔗 Симлинк $tempPath удалён."
        } else {
            Write-Host "⚠️ $tempPath существует, но это не симлинк. Пропускаю."
        }
    }

    # Отмонтирование и удаление VHD
    if (Test-Path $vhdPath) {
        try {
            Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
        } catch {}
        Remove-Item $vhdPath -Force
        Write-Host "🗑️ Виртуальный диск и файл $vhdPath удалены."
    } else {
        Write-Host "⚠️ Файл $vhdPath не найден."
    }
}

# Меню
while ($true) {
    Write-Host ""
    Write-Host "=== Roblox Sounds VHD Manager ==="
    Write-Host "1) Создать и подключить диск"
    Write-Host "2) Удалить диск и симлинк"
    Write-Host "3) Выйти"
    $choice = Read-Host "Выберите действие (1-3)"

    switch ($choice) {
        "1" { Create-VHD }
        "2" { Remove-VHD }
        "3" { break }
        default { Write-Host "❌ Неверный выбор" }
    }
}
