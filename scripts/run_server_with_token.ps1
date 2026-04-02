<#
.SYNOPSIS
    Run the MCP Agent Mail server with the bearer token from .env
#>

$envFile = Join-Path $PSScriptRoot "..\.env"
if (Test-Path $envFile) {
    $content = Get-Content $envFile
    foreach ($line in $content) {
        if ($line -match "^HTTP_BEARER_TOKEN=(.*)") {
            $env:HTTP_BEARER_TOKEN = $Matches[1].Trim("'").Trim('"')
        }
        if ($line -match "^HTTP_PORT=(.*)") {
            $env:HTTP_PORT = $Matches[1].Trim("'").Trim('"')
        }
    }
}

# Ensure uv is in PATH
$uvPath = Join-Path $HOME ".local\bin"
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $uvPath "uv.exe")) {
        $env:PATH = "$uvPath;$env:PATH"
    }
}

Write-Host "Starting MCP Agent Mail server..." -ForegroundColor Green
uv run python -m mcp_agent_mail.cli serve-http
