<#
.SYNOPSIS
    OpenAI Codex CLI Integration (PowerShell)
#>

param (
    [switch]$Yes = $false,
    [string]$ProjectDir = ""
)

$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $PSScriptRoot "lib.ps1")

if ($Yes) { $env:AUTO_YES = "1" }

Write-LogStep "OpenAI Codex CLI Integration (one-stop MCP config) - PowerShell"

$rootDir = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
$targetDir = if ([string]::IsNullOrWhiteSpace($ProjectDir)) { $rootDir } else { Resolve-Path $ProjectDir | Select-Object -ExpandProperty Path }

if (-not (Confirm-Action "Proceed?")) { Write-LogWarn "Aborted."; exit 1 }

Write-LogStep "Resolving HTTP endpoint from settings"
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

# Write project-local codex.mcp.json
$outJson = Join-Path $targetDir "codex.mcp.json"
Backup-File $outJson
$mcpConfig = @{
    "type" = "http"
    "url"  = $url
}
if ($token) { $mcpConfig.headers = @{ "Authorization" = "Bearer $token" } }
$config = @{ "mcpServers" = @{ "mcp-agent-mail" = $mcpConfig } }
$config | ConvertTo-Json -Depth 10 | Set-Content $outJson
Write-LogOk "Wrote $outJson"

# Bootstrap
$agentName = "YOUR_AGENT_NAME"
if (Test-ServerReadiness $hostName $port $path) {
    Write-LogOk "Server readiness OK."
    $authHeader = if ($token) { @{ "Authorization" = "Bearer $token" } } else { @{} }
    
    # ensure_project
    $body = @{
        "jsonrpc" = "2.0"
        "id"      = "1"
        "method"  = "tools/call"
        "params"  = @{
            "name"      = "ensure_project"
            "arguments" = @{ "human_key" = $targetDir }
        }
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Headers $authHeader -Body $body | Out-Null

    # register_agent
    $body = @{
        "jsonrpc" = "2.0"
        "id"      = "2"
        "method"  = "tools/call"
        "params"  = @{
            "name"      = "register_agent"
            "arguments" = @{
                "project_key"      = $targetDir
                "program"          = "codex-cli"
                "model"            = "gpt-5-codex"
                "task_description" = "setup"
            }
        }
    } | ConvertTo-Json
    $response = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Headers $authHeader -Body $body
    try {
        $resObj = $response.result.content[0].text | ConvertFrom-Json
        $agentName = $resObj.name
        Write-LogOk "Registered agent: $agentName"
    } catch {
        Write-LogWarn "Could not parse agent name from response"
    }
}

# Update user-level ~/.codex/config.toml (best effort)
$codexDir = Join-Path $HOME ".codex"
if (-not (Test-Path $codexDir)) { New-Item -ItemType Directory -Path $codexDir -Force | Out-Null }
$userToml = Join-Path $codexDir "config.toml"
Backup-File $userToml

# Use Python for TOML manipulation parity
$tomlPyScript = @'
import re, sys
from pathlib import Path
path, url = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8") if path.exists() else ""
if "[mcp_servers.mcp_agent_mail]" not in text:
    with path.open("a", encoding="utf-8") as f:
        f.write(f'\n[mcp_servers.mcp_agent_mail]\nurl = "{url}"\n')
else:
    text = re.sub(r'\[mcp_servers\.mcp_agent_mail\]\s*\nurl\s*=\s*".*?"', f'[mcp_servers.mcp_agent_mail]\nurl = "{url}"', text)
    path.write_text(text, encoding="utf-8")
'@
uv run python -c $tomlPyScript $userToml $url

Write-LogOk "==> Done."
if ($agentName -ne "YOUR_AGENT_NAME") { Write-Host "Your agent name is: $agentName" }
