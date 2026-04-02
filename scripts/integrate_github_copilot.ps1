<#
.SYNOPSIS
    GitHub Copilot Integration (PowerShell)
#>

param (
    [switch]$Yes = $false,
    [string]$ProjectDir = ""
)

$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $PSScriptRoot "lib.ps1")

if ($Yes) { $env:AUTO_YES = "1" }

Write-LogStep "GitHub Copilot Integration (MCP Support) - PowerShell"

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

# Write VS Code workspace MCP configuration
$vscodeDir = Join-Path $targetDir ".vscode"
if (-not (Test-Path $vscodeDir)) { New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null }
$mcpJson = Join-Path $vscodeDir "mcp.json"
Backup-File $mcpJson

$mcpConfig = @{
    "type" = "http"
    "url"  = $url
}
if ($token) { $mcpConfig.headers = @{ "Authorization" = "Bearer $token" } }

$config = if (Test-Path $mcpJson) { Get-Content $mcpJson -Raw | ConvertFrom-Json } else { New-Object PSObject }
if (-not $config.PSObject.Properties.Item("servers")) { 
    $config | Add-Member -MemberType NoteProperty -Name "servers" -Value (New-Object PSObject)
}
if ($config.servers.PSObject.Properties.Item("mcp-agent-mail")) {
    $config.servers."mcp-agent-mail" = $mcpConfig
} else {
    $config.servers | Add-Member -MemberType NoteProperty -Name "mcp-agent-mail" -Value $mcpConfig
}
$config | ConvertTo-Json -Depth 10 | Set-Content $mcpJson
Write-LogOk "Wrote $mcpJson"

# Bootstrap
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
                "program"          = "github-copilot"
                "model"            = "gpt-4"
                "name"             = $env:USERNAME
                "task_description" = "setup"
            }
        }
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Headers $authHeader -Body $body | Out-Null
    Write-LogOk "Registered agent on server"
}

Write-LogOk "==> Done."
