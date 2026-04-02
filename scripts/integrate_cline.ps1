<#
.SYNOPSIS
    Cline Integration (PowerShell)
#>

param (
    [switch]$Yes = $false,
    [string]$ProjectDir = ""
)

$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $PSScriptRoot "lib.ps1")

if ($Yes) { $env:AUTO_YES = "1" }

Write-LogStep "Cline Integration (HTTP MCP) - PowerShell"

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

# Write project-local Cline MCP config snippet
$outJson = Join-Path $targetDir "cline.mcp.json"
Backup-File $outJson

$mcpConfig = @{
    "type" = "http"
    "url"  = $url
    "note" = "Import or configure this server in Cline's MCP settings"
}
if ($token) {
    $mcpConfig.headers = @{ "Authorization" = "Bearer $token" }
}

$config = @{
    "mcpServers" = @{
        "mcp-agent-mail" = $mcpConfig
    }
}
$config | ConvertTo-Json -Depth 10 | Set-Content $outJson
Write-LogOk "Wrote $outJson"

# Bootstrap
if (Test-ServerReadiness $hostName $port $path) {
    Write-LogOk "Server readiness OK."
    $authHeader = if ($token) { @{ "Authorization" = "Bearer $token" } } else { @{} }
    $humanKey = $targetDir
    $agentName = $env:USERNAME

    # ensure_project
    $body = @{
        "jsonrpc" = "2.0"
        "id"      = "1"
        "method"  = "tools/call"
        "params"  = @{
            "name"      = "ensure_project"
            "arguments" = @{ "human_key" = $humanKey }
        }
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Headers $authHeader -Body $body | Out-Null
    Write-LogOk "Ensured project on server"

    # register_agent
    $body = @{
        "jsonrpc" = "2.0"
        "id"      = "2"
        "method"  = "tools/call"
        "params"  = @{
            "name"      = "register_agent"
            "arguments" = @{
                "project_key"      = $humanKey
                "program"          = "cline"
                "model"            = "default"
                "name"             = $agentName
                "task_description" = "setup"
            }
        }
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Headers $authHeader -Body $body | Out-Null
    Write-LogOk "Registered agent on server"
} else {
    Write-LogWarn "Server not reachable. Skipping bootstrap."
}

Write-LogOk "==> Done."
