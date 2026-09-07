param(
    [ValidateSet('install', 'status', 'uninstall', 'watch', 'once', 'self-test')]
    [string]$Action = 'status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StartupName = 'CCSwitchClaudeDesktopAutoMode'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'CCSwitchClaudeAutoMode'
$InstalledScript = Join-Path $InstallDirectory 'claude-desktop-auto-mode.ps1'
$DefaultConfigLibrary = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
$StopEventName = 'Local\CCSwitchClaudeDesktopAutoModeStop'

function Get-ActiveProfilePath {
    param([string]$ConfigLibrary)

    $metaPath = Join-Path $ConfigLibrary '_meta.json'
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        return $null
    }

    $meta = [IO.File]::ReadAllText($metaPath) | ConvertFrom-Json
    $appliedProperty = $meta.PSObject.Properties['appliedId']
    if ($null -eq $appliedProperty) {
        return $null
    }

    $profileId = [string]$appliedProperty.Value
    if ([string]::IsNullOrWhiteSpace($profileId) -or
        [IO.Path]::GetFileName($profileId) -ne $profileId -or
        $profileId.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Claude Desktop appliedId is not a safe file name.'
    }

    Join-Path $ConfigLibrary ($profileId + '.json')
}

function Repair-ActiveProfile {
    param(
        [string]$ConfigLibrary,
        [switch]$ReadOnly
    )

    if (-not (Test-Path -LiteralPath $ConfigLibrary -PathType Container)) {
        return [pscustomobject]@{ Status = 'NoConfigLibrary'; Profile = $null }
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $temporaryPath = $null
        $backupPath = $null
        try {
            $profilePath = Get-ActiveProfilePath -ConfigLibrary $ConfigLibrary
            if ($null -eq $profilePath -or -not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
                return [pscustomobject]@{ Status = 'NoActiveProfile'; Profile = $profilePath }
            }

            $originalJson = [IO.File]::ReadAllText($profilePath)
            $profile = $originalJson | ConvertFrom-Json
            $providerProperty = $profile.PSObject.Properties['inferenceProvider']
            if ($null -eq $providerProperty -or $providerProperty.Value -ne 'gateway') {
                return [pscustomobject]@{ Status = 'NotGateway'; Profile = $profilePath }
            }

            $autoProperty = $profile.PSObject.Properties['autoModeEnabled']
            if ($null -ne $autoProperty -and $autoProperty.Value -eq $true) {
                return [pscustomobject]@{ Status = 'AlreadyEnabled'; Profile = $profilePath }
            }
            if ($ReadOnly) {
                return [pscustomobject]@{ Status = 'NeedsUpdate'; Profile = $profilePath }
            }

            $profile | Add-Member -NotePropertyName autoModeEnabled -NotePropertyValue $true -Force
            $updatedJson = ($profile | ConvertTo-Json -Depth 100) + [Environment]::NewLine
            $temporaryPath = Join-Path $ConfigLibrary ('.auto-mode-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($temporaryPath, $updatedJson, [Text.UTF8Encoding]::new($false))

            if ([IO.File]::ReadAllText($profilePath) -ne $originalJson) {
                Remove-Item -LiteralPath $temporaryPath -Force
                $temporaryPath = $null
                Start-Sleep -Milliseconds 300
                continue
            }

            $backupPath = Join-Path $ConfigLibrary ('.auto-mode-' + [Guid]::NewGuid().ToString('N') + '.bak')
            [IO.File]::Replace($temporaryPath, $profilePath, $backupPath, $true)
            $temporaryPath = $null
            Remove-Item -LiteralPath $backupPath -Force
            $backupPath = $null
            return [pscustomobject]@{ Status = 'Updated'; Profile = $profilePath }
        } catch {
            if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
            if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            if ($attempt -eq 5) {
                return [pscustomobject]@{ Status = 'Busy'; Profile = $profilePath; Error = $_.Exception.Message }
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Start-Watcher {
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, 'Local\CCSwitchClaudeDesktopAutoMode', [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return
    }

    $stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $StopEventName)
    try {
        while (-not $stopEvent.WaitOne(0)) {
            if (-not (Test-Path -LiteralPath $DefaultConfigLibrary -PathType Container)) {
                if ($stopEvent.WaitOne(10000)) {
                    break
                }
                continue
            }

            Repair-ActiveProfile -ConfigLibrary $DefaultConfigLibrary | Out-Null
            $watcher = [IO.FileSystemWatcher]::new($DefaultConfigLibrary, '*.json')
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, CreationTime'
            try {
                while (Test-Path -LiteralPath $DefaultConfigLibrary -PathType Container) {
                    $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 30000)
                    if ($stopEvent.WaitOne(0)) {
                        break
                    }
                    if (-not $change.TimedOut) {
                        Start-Sleep -Milliseconds 300
                    }
                    Repair-ActiveProfile -ConfigLibrary $DefaultConfigLibrary | Out-Null
                }
            } finally {
                $watcher.Dispose()
            }
        }
    } finally {
        $stopEvent.Dispose()
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Show-Status {
    $startupCommand = Get-ItemPropertyValue -LiteralPath $RunKey -Name $StartupName -ErrorAction SilentlyContinue
    $repair = Repair-ActiveProfile -ConfigLibrary $DefaultConfigLibrary -ReadOnly
    [pscustomobject]@{
        Installed = Test-Path -LiteralPath $InstalledScript -PathType Leaf
        StartupRegistered = -not [string]::IsNullOrWhiteSpace([string]$startupCommand)
        Profile = $repair.Profile
        AutoMode = $repair.Status
    } | Format-List
}

function Install-Watcher {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
    }

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startupCommand = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" watch' -f $powerShell, $InstalledScript
    if (-not (Test-Path -LiteralPath $RunKey)) {
        New-Item -Path $RunKey -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $RunKey -Name $StartupName -PropertyType String -Value $startupCommand -Force | Out-Null

    & $InstalledScript once | Out-Null
    Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" watch' -f $InstalledScript)
    Start-Sleep -Milliseconds 500
    Show-Status
}

function Uninstall-Watcher {
    Remove-ItemProperty -LiteralPath $RunKey -Name $StartupName -ErrorAction SilentlyContinue
    try {
        $stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
        $stopEvent.Set() | Out-Null
        $stopEvent.Dispose()
        if (Test-Path -LiteralPath $DefaultConfigLibrary -PathType Container) {
            $wakePath = Join-Path $DefaultConfigLibrary '._ccswitch-auto-mode-stop.json'
            [IO.File]::WriteAllText($wakePath, '{}')
            Remove-Item -LiteralPath $wakePath -Force
        }
        Start-Sleep -Milliseconds 500
    } catch {
        # No watcher is running.
    }
    if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    }
    'Removed the logon startup entry and local runtime copy. The Claude Desktop profile was left unchanged.'
}

function Invoke-SelfTest {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-auto-mode-' + [Guid]::NewGuid().ToString('N'))
    $configLibrary = Join-Path $testRoot 'configLibrary'
    $profileId = [Guid]::NewGuid().ToString()
    $profilePath = Join-Path $configLibrary ($profileId + '.json')
    try {
        New-Item -ItemType Directory -Path $configLibrary -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $configLibrary '_meta.json'), ('{{"appliedId":"{0}"}}' -f $profileId))
        $original = [ordered]@{
            inferenceProvider = 'gateway'
            inferenceGatewayBaseUrl = 'https://another-relay.example/v1'
            inferenceGatewayApiKey = 'test-secret'
            inferenceModels = @('model-a', 'model-b')
        }
        [IO.File]::WriteAllText($profilePath, ($original | ConvertTo-Json -Depth 10))

        $beforeStatus = [IO.File]::ReadAllText($profilePath)
        if ((Repair-ActiveProfile -ConfigLibrary $configLibrary -ReadOnly).Status -ne 'NeedsUpdate' -or
            [IO.File]::ReadAllText($profilePath) -ne $beforeStatus) {
            throw 'Self-test failed: status inspection changed the profile.'
        }

        $result = Repair-ActiveProfile -ConfigLibrary $configLibrary
        $actual = [IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $actualAutoProperty = $actual.PSObject.Properties['autoModeEnabled']
        $actualAuto = if ($null -eq $actualAutoProperty) { $null } else { $actualAutoProperty.Value }
        $resultErrorProperty = $result.PSObject.Properties['Error']
        $resultError = if ($null -eq $resultErrorProperty) { $null } else { $resultErrorProperty.Value }
        if ($result.Status -ne 'Updated' -or
            $actualAuto -ne $true -or
            $actual.inferenceGatewayBaseUrl -ne $original.inferenceGatewayBaseUrl -or
            $actual.inferenceGatewayApiKey -ne $original.inferenceGatewayApiKey -or
            @($actual.inferenceModels).Count -ne 2) {
            throw ('Self-test failed: status={0}, auto={1}, relayPreserved={2}, keyPreserved={3}, modelCount={4}, error={5}.' -f
                $result.Status,
                $actualAuto,
                ($actual.inferenceGatewayBaseUrl -eq $original.inferenceGatewayBaseUrl),
                ($actual.inferenceGatewayApiKey -eq $original.inferenceGatewayApiKey),
                @($actual.inferenceModels).Count,
                $resultError)
        }

        if ((Repair-ActiveProfile -ConfigLibrary $configLibrary).Status -ne 'AlreadyEnabled') {
            throw 'Self-test failed: repeated repair was not idempotent.'
        }
        'Self-test passed: dynamic profile, relay URL, key, and model list were preserved.'
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

switch ($Action) {
    'install' { Install-Watcher }
    'status' { Show-Status }
    'uninstall' { Uninstall-Watcher }
    'watch' { Start-Watcher }
    'once' { Repair-ActiveProfile -ConfigLibrary $DefaultConfigLibrary | Format-List }
    'self-test' { Invoke-SelfTest }
}
