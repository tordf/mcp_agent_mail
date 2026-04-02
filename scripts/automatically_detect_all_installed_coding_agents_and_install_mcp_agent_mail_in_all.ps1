<#
.SYNOPSIS
    MCP Agent Mail: Auto-detect and Integrate with Installed Coding Agents (PowerShell)
#>

param (
    [switch]$Yes = $false,
    [string]$ProjectDir = ""
)

$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $PSScriptRoot "lib.ps1")

if ($Yes) { $env:AUTO_YES = "1" }

Write-LogStep "MCP Agent Mail: Auto-detect and Integrate with Installed Coding Agents - PowerShell"
Write-Host ""
Write-Host "This will detect local agent configs under ~/.claude, ~/.codex, ~/.cursor, ~/.gemini and generate per-agent MCP configs."
Write-Host ""

if (-not (Confirm-Action "Proceed?")) { Write-LogWarn "Aborted."; exit 1 }

$rootDir = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
$targetDir = if ([string]::IsNullOrWhiteSpace($ProjectDir)) { $rootDir } else { Resolve-Path $ProjectDir | Select-Object -ExpandProperty Path }

# Detect agents
$hasClaude = Test-Path (Join-Path $HOME ".claude")
$hasCodex = Test-Path (Join-Path $HOME ".codex")
$hasCursor = Test-Path (Join-Path $HOME ".cursor")
$hasGemini = Test-Path (Join-Path $HOME ".gemini")

Write-LogInfo "Found: claude=$hasClaude, codex=$hasCodex, cursor=$hasCursor, gemini=$hasGemini"

# Start temporary server for bootstrap
$pyScript = @'
from mcp_agent_mail.config import get_settings
s = get_settings()
print(f"{s.http.host}|{s.http.port}")
'@
$settingsRaw = $pyScript | uv run python -
$hostName, $port = $settingsRaw.Split("|")

if (-not (Test-ServerReadiness $hostName $port "/health/readiness" 1 0.1)) {
    Write-LogStep "Starting temporary server for bootstrap"
    $serverJob = Start-ServerBackground
    if (-not (Test-ServerReadiness $hostName $port "/health/readiness" 20 0.5)) {
        Write-LogWarn "Temporary server not ready; proceeding without bootstrap."
    }
}

if ($hasClaude) {
    Write-Host "-- Integrating Claude Code..."
    & (Join-Path $PSScriptRoot "integrate_claude_code.ps1") -Yes:$Yes -ProjectDir $targetDir
}

if ($hasCursor) {
    Write-Host "-- Integrating Cursor..."
    & (Join-Path $PSScriptRoot "integrate_cursor.ps1") -Yes:$Yes -ProjectDir $targetDir
}

if ($hasCodex) {
    Write-Host "-- Integrating Codex CLI..."
    & (Join-Path $PSScriptRoot "integrate_codex_cli.ps1") -Yes:$Yes -ProjectDir $targetDir
}

if ($hasGemini) {
    Write-Host "-- Integrating Gemini CLI..."
    & (Join-Path $PSScriptRoot "integrate_gemini_cli.ps1") -Yes:$Yes -ProjectDir $targetDir
}

# Best-effort integrations
Write-Host "-- Integrating Cline (best effort)..."
& (Join-Path $PSScriptRoot "integrate_cline.ps1") -Yes:$Yes -ProjectDir $targetDir

Write-Host "-- Integrating Windsurf (best effort)..."
& (Join-Path $PSScriptRoot "integrate_windsurf.ps1") -Yes:$Yes -ProjectDir $targetDir

Write-Host "-- Integrating GitHub Copilot (VS Code + IDE MCP support)..."
& (Join-Path $PSScriptRoot "integrate_github_copilot.ps1") -Yes:$Yes -ProjectDir $targetDir

Write-LogOk "Summary: Integration check complete."

if ($null -ne $serverJob) {
    Write-LogStep "Stopping temporary server"
    Stop-Process $serverJob -Force -ErrorAction SilentlyContinue
}

Write-Host "Run server with: .\scripts\run_server_with_token.ps1"
Write-LogOk "All done."
