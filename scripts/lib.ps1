<#
.SYNOPSIS
    Shared helpers for MCP Agent Mail PowerShell scripts
#>

# Initialize colors
$script:ColorMap = @{
    Info = "Cyan"
    Ok   = "Green"
    Warn = "Yellow"
    Err  = "Red"
    Step = "Magenta"
}

# Ensure uv is in PATH
$uvPath = Join-Path $HOME ".local\bin"
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $uvPath "uv.exe")) {
        $env:PATH = "$uvPath;$env:PATH"
    }
}

function Write-LogStep($msg) { Write-Host "==> $msg" -ForegroundColor $script:ColorMap.Step }
function Write-LogOk($msg)   { Write-Host "$msg" -ForegroundColor $script:ColorMap.Ok }
function Write-LogWarn($msg) { Write-Host "$msg" -ForegroundColor $script:ColorMap.Warn }
function Write-LogErr($msg)  { Write-Host "$msg" -ForegroundColor $script:ColorMap.Err }
function Write-LogInfo($msg) { Write-Host "$msg" -ForegroundColor $script:ColorMap.Info }

# Check for command existence
function Test-Command($cmd) {
    return (Get-Command $cmd -ErrorAction SilentlyContinue) -ne $null
}

# Require a command or exit
function Require-Command($cmd) {
    if (-not (Test-Command $cmd)) {
        Write-LogErr "Missing dependency: $cmd"
        exit 1
    }
}

# Safe file writing (atomic-ish on Windows)
function Write-Atomic($path, $content) {
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    $tmp = "$path.tmp.$(Get-Random)"
    $content | Set-Content $tmp -Encoding UTF8
    
    if (Test-Path $path) {
        Remove-Item $path -Force
    }
    Move-Item $tmp $path -Force
}

# JSON validation
function Test-Json($path) {
    try {
        Get-Content $path -Raw | ConvertFrom-Json | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Backup a file
function Backup-File($path) {
    if (-not (Test-Path $path)) { return }
    
    $backupDir = Join-Path $PSScriptRoot "..\backup_config_files"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    $fileName = Split-Path $path -Leaf
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = Join-Path $backupDir "$fileName.$timestamp.bak"
    
    Copy-Item $path $backupPath -Force
    Write-LogInfo "Backed up $path to $backupPath"
}

# Update .env variable
function Update-EnvVar($key, $value) {
    $envFile = Join-Path $PSScriptRoot "..\.env"
    $line = "$key=$value"
    
    if (Test-Path $envFile) {
        $lines = Get-Content $envFile
        $found = $false
        $newLines = New-Object System.Collections.Generic.List[string]
        foreach ($l in $lines) {
            if ($l -match "^$key=") {
                $newLines.Add($line)
                $found = $true
            } else {
                $newLines.Add($l)
            }
        }
        if (-not $found) { $newLines.Add($line) }
        $newLines | Set-Content $envFile
    } else {
        $line | Set-Content $envFile
    }
}

# Readiness poll
function Test-ServerReadiness($hostName, $port, $path, $tries = 3, $delay = 0.5) {
    $url = "http://$($hostName):$($port)$($path)"
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds $delay
    }
    return $false
}

# Confirmation prompt
function Confirm-Action($msg) {
    if ($env:AUTO_YES -eq "1") { return $true }
    $ans = Read-Host "$msg [y/N]"
    return $ans -match "^[yY]"
}

# Start server in background
function Start-ServerBackground {
    $helper = Resolve-Path (Join-Path $PSScriptRoot "run_server_with_token.ps1")
    $rootDir = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logDir = Join-Path $rootDir "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "server_$stamp.log"
    
    # Use Start-Process for a persistent background process
    $proc = Start-Process powershell -ArgumentList "-ExecutionPolicy ByPass -NoProfile -File `"$($helper.Path)`"" -WorkingDirectory $rootDir -RedirectStandardOutput $logFile -RedirectStandardError $logFile -PassThru -WindowStyle Hidden
    
    Write-LogInfo "Server starting in background (PID: $($proc.Id), Log: $logFile)"
    return $proc
}

# JSON helpers
function Json-EscapeString($str) {
    return $str | ConvertTo-Json
}

function Json-MergeMcpServer($existing, $serverName, $serverConfig) {
    if ($existing -is [string]) { $existing = $existing | ConvertFrom-Json }
    if (-not $existing.PSObject.Properties.Item("mcpServers")) { 
        $existing | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value (New-Object PSObject)
    }
    # Use Add-Member to handle property names with dashes/special characters
    if ($existing.mcpServers.PSObject.Properties.Item($serverName)) {
        $existing.mcpServers.$serverName = $serverConfig
    } else {
        $existing.mcpServers | Add-Member -MemberType NoteProperty -Name $serverName -Value $serverConfig
    }
    return $existing
}
