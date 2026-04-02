<#
.SYNOPSIS
    Claude Code Integration (PowerShell)
#>

param (
    [switch]$Yes = $false,
    [string]$ProjectDir = ""
)

$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $PSScriptRoot "lib.ps1")

if ($Yes) { $env:AUTO_YES = "1" }

Write-LogStep "Claude Code Integration (HTTP MCP + Hooks) - PowerShell"

$rootDir = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
$targetDir = if ([string]::IsNullOrWhiteSpace($ProjectDir)) { $rootDir } else { Resolve-Path $ProjectDir | Select-Object -ExpandProperty Path }

if (-not (Confirm-Action "Proceed?")) { Write-LogWarn "Aborted."; exit 1 }

Write-LogStep "Resolving HTTP endpoint from settings"
# Get settings via python (most reliable way to ensure consistency)
$pyScript = @'
from mcp_agent_mail.config import get_settings
s = get_settings()
print(f"{s.http.host}|{s.http.port}|{s.http.path}")
'@
$settingsRaw = $pyScript | uv run python -
$hostName, $port, $path = $settingsRaw.Split("|")

$url = "http://$($hostName):$($port)$($path)"
Write-LogOk "Detected MCP HTTP endpoint: $url"

# Resolve token
$envFile = Join-Path $rootDir ".env"
$token = if (Test-Path $envFile) {
    (Get-Content $envFile | Where-Object { $_ -match "^HTTP_BEARER_TOKEN=(.*)" }) -replace "^HTTP_BEARER_TOKEN=", ""
} else { $null }

if ([string]::IsNullOrWhiteSpace($token)) {
    $token = uv run python -c "import secrets; print(secrets.token_hex(32))"
    Update-EnvVar "HTTP_BEARER_TOKEN" $token
    Write-LogOk "Generated bearer token."
}

Write-LogStep "Preparing project-local .claude\settings.json"
$claudeDir = Join-Path $targetDir ".claude"
$settingsPath = Join-Path $claudeDir "settings.json"
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

if (Test-Path $settingsPath) { Backup-File $settingsPath }

# Build hook configs as JSON
$mcpConfig = @{
    "type"    = "http"
    "url"     = $url
    "headers" = @{
        "Authorization" = "Bearer $token"
    }
}

# Update settings.local.json with secrets
$localSettingsPath = Join-Path $claudeDir "settings.local.json"
if (Test-Path $localSettingsPath) { Backup-File $localSettingsPath }
$localSettings = if (Test-Path $localSettingsPath) { Get-Content $localSettingsPath -Raw | ConvertFrom-Json } else { @{} }
if (-not $localSettings.PSObject.Properties.Item("mcpServers")) { $localSettings.mcpServers = @{} }
$localSettings.mcpServers."mcp-agent-mail" = $mcpConfig
$localSettings | ConvertTo-Json -Depth 10 | Set-Content $localSettingsPath

Write-LogOk "Updated $localSettingsPath with MCP server (token secured)"

# Ensure .gitignore
$gitignorePath = Join-Path $targetDir ".gitignore"
if (Test-Path $gitignorePath) {
    if (-not (Get-Content $gitignorePath | Where-Object { $_ -match ".claude/settings.local.json" })) {
        Add-Content $gitignorePath "`n# Claude Code local settings (contains secrets)`n.claude/settings.local.json"
    }
}

# Update global user-level ~/.claude/settings.json
$homeClaudeDir = Join-Path $HOME ".claude"
if (-not (Test-Path $homeClaudeDir)) { New-Item -ItemType Directory -Path $homeClaudeDir -Force | Out-Null }
$homeSettingsPath = Join-Path $homeClaudeDir "settings.json"

if (Test-Path $homeSettingsPath) { Backup-File $homeSettingsPath }
$homeSettings = if (Test-Path $homeSettingsPath) { Get-Content $homeSettingsPath -Raw | ConvertFrom-Json } else { New-Object PSObject }
$homeSettings = Json-MergeMcpServer $homeSettings "mcp-agent-mail" $mcpConfig
$homeSettings | ConvertTo-Json -Depth 10 | Set-Content $homeSettingsPath
Write-LogOk "Updated global $homeSettingsPath with MCP server"

# Register with Claude Code CLI if available
if (Test-Command "claude") {
    Write-LogStep "Registering MCP server with Claude CLI"
    try {
        # User scope - remove first to ensure update
        & claude mcp remove --scope user mcp-agent-mail 2>$null
        & claude mcp add --transport http --scope user mcp-agent-mail $url -H "Authorization: Bearer $token"
        
        # Project scope - remove first to ensure update
        Push-Location $targetDir
        & claude mcp remove --scope project mcp-agent-mail 2>$null
        & claude mcp add --transport http --scope project mcp-agent-mail $url -H "Authorization: Bearer $token"
        Pop-Location
        
        Write-LogOk "Registered and updated Claude CLI config."
    } catch {
        Write-LogWarn "Failed to register with Claude CLI command (non-fatal)."
    }
}

Write-LogOk "==> Done."
