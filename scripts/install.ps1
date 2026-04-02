<#
.SYNOPSIS
    MCP Agent Mail — TL;DR installer for Windows (PowerShell)
    - Installs uv (if missing)
    - Sets up Python 3.14 venv with uv
    - Syncs dependencies
    - Runs auto-detect integration and starts the HTTP server on port 8765

.EXAMPLE
    .\scripts\install.ps1 -Yes
#>

param (
    [string]$Dir = "",
    [string]$Branch = "main",
    [int]$Port = 0,
    [switch]$Yes = $false,
    [switch]$NoStart = $false,
    [switch]$StartOnly = $false,
    [string]$ProjectDir = "",
    [string]$Token = "",
    [switch]$SkipBeads = $false,
    [switch]$SkipBv = $false
)

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/Dicklesworthstone/mcp_agent_mail"
$RepoName = "mcp_agent_mail"
$Branch = "main"
$DefaultCloneDir = Join-Path $PWD $RepoName
$CloneDir = if ([string]::IsNullOrWhiteSpace($Dir)) { $DefaultCloneDir } else { Resolve-Path $Dir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -Default $Dir }
$SummaryLines = New-Object System.Collections.Generic.List[string]

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERR ] $msg" -ForegroundColor Red }

function Need-Cmd($cmd) {
    return (Get-Command $cmd -ErrorAction SilentlyContinue) -ne $null
}

function Record-Summary($msg) {
    $SummaryLines.Add($msg)
}

function Print-Summary {
    if ($SummaryLines.Count -eq 0) { return }
    Write-Host ""
    Write-Info "Installation summary"
    foreach ($line in $SummaryLines) {
        Write-Host "  - $line"
    }
}

function Ensure-Uv {
    if (Need-Cmd "uv") {
        Write-Ok "uv is already installed"
        Record-Summary "uv: already installed"
        return
    }
    Write-Info "Installing uv (Astral)"
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    # Refresh PATH for current session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if (Need-Cmd "uv") {
        Write-Ok "uv installed"
        Record-Summary "uv: installed"
    } else {
        Write-Err "uv install failed"
        exit 1
    }
}

function Update-ExistingRepo($repoPath) {
    Write-Info "Pulling latest changes from origin/$Branch"
    Push-Location $repoPath
    try {
        git fetch origin $Branch --depth 1
        $localSha = git rev-parse HEAD
        $remoteSha = git rev-parse "origin/$Branch"

        if ($localSha -eq $remoteSha) {
            Write-Ok "Already up to date ($($localSha.Substring(0,8)))"
            Record-Summary "Repo: already up to date"
            return
        }

        $hasChanges = (git status --porcelain) -ne $null
        if ($hasChanges) {
            Write-Info "Stashing local changes before update"
            git stash push -m "installer-auto-stash-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }

        git reset --hard "origin/$Branch"
        Write-Ok "Updated to latest ($($localSha.Substring(0,8)) → $($remoteSha.Substring(0,8)))"
        Record-Summary "Repo: updated $($localSha.Substring(0,8)) → $($remoteSha.Substring(0,8))"

        if ($hasChanges) {
            git stash pop
            Write-Ok "Restored local changes"
        }
    } catch {
        Write-Warn "Could not update repo; continuing with existing code"
        Record-Summary "Repo: update failed, using existing"
    } finally {
        Pop-Location
    }
}

function Ensure-Repo {
    # If we're already in the repo (local run), use it and update
    if (Test-Path "pyproject.toml") {
        $content = Get-Content "pyproject.toml" -Raw
        if ($content -match 'name\s*=\s*"mcp-agent-mail"') {
            $script:RepoDir = $PWD.Path
            Write-Ok "Using existing repo at: $script:RepoDir"
            Update-ExistingRepo $script:RepoDir
            return
        }
    }

    # If directory exists and looks like the repo, use it and update
    if (Test-Path $CloneDir) {
        $pyproject = Join-Path $CloneDir "pyproject.toml"
        if (Test-Path $pyproject) {
            $content = Get-Content $pyproject -Raw
            if ($content -match 'name\s*=\s*"mcp-agent-mail"') {
                $script:RepoDir = $CloneDir
                Write-Ok "Using existing repo at: $script:RepoDir"
                Update-ExistingRepo $script:RepoDir
                return
            }
        }
    }

    # Otherwise clone
    Write-Info "Cloning $RepoUrl (branch=$Branch) to $CloneDir"
    if (-not (Need-Cmd "git")) {
        Write-Err "git is required to clone"
        exit 1
    }
    git clone --depth 1 --branch $Branch $RepoUrl $CloneDir
    $script:RepoDir = $CloneDir
    Write-Ok "Cloned repo"
    Record-Summary "Repo: cloned into $script:RepoDir"
}

function Ensure-PythonAndVenv {
    Write-Info "Ensuring Python 3.14 and project venv (.venv)"
    Push-Location $RepoDir
    try {
        uv python install 3.14
        $venvPath = Join-Path $RepoDir ".venv"
        if (-not (Test-Path $venvPath)) {
            uv venv -p 3.14
            Write-Ok "Created venv at $venvPath"
            Record-Summary "Venv: created at $venvPath"
        } else {
            Write-Ok "Found existing venv at $venvPath"
            Record-Summary "Venv: existing at $venvPath"
        }
    } finally {
        Pop-Location
    }
}

function Sync-Deps {
    Write-Info "Syncing dependencies with uv"
    Push-Location $RepoDir
    try {
        uv sync
    } finally {
        Pop-Location
    }
    Write-Ok "Dependencies installed"
    Record-Summary "Dependencies: uv sync complete"
}

function Configure-Port {
    if ($Port -eq 0) { return }
    if ($Port -lt 1 -or $Port -gt 65535) {
        Write-Err "Port must be between 1 and 65535 (got: $Port)"
        exit 1
    }

    $envFile = Join-Path $RepoDir ".env"
    Write-Info "Configuring HTTP_PORT=$Port in .env"

    if (Test-Path $envFile) {
        $lines = Get-Content $envFile
        $newLines = New-Object System.Collections.Generic.List[string]
        $found = $false
        foreach ($line in $lines) {
            if ($line -match "^HTTP_PORT=") {
                $newLines.Add("HTTP_PORT=$Port")
                $found = $true
            } else {
                $newLines.Add($line)
            }
        }
        if (-not $found) {
            $newLines.Add("HTTP_PORT=$Port")
        }
        $newLines | Set-Content $envFile
    } else {
        "HTTP_PORT=$Port" | Set-Content $envFile
    }
    Write-Ok "HTTP_PORT set to $Port"
    Record-Summary "HTTP port: $Port"
}

function Run-IntegrationAndStart {
    if ($NoStart) {
        Write-Warn "-NoStart specified; skipping integration/start"
        return
    }
    Write-Info "Running auto-detect integration and starting server"
    Push-Location $RepoDir
    try {
        if ($Token) { $env:INTEGRATION_BEARER_TOKEN = $Token }
        
        # On Windows, we prefer the native PowerShell integration script
        $psIntegration = Join-Path $RepoDir "scripts\automatically_detect_all_installed_coding_agents_and_install_mcp_agent_mail_in_all.ps1"
        if (Test-Path $psIntegration) {
            $params = @{}
            if ($Yes) { $params["Yes"] = $true }
            if ($ProjectDir) { $params["ProjectDir"] = $ProjectDir }
            & $psIntegration @params
        } elseif (Need-Cmd "bash") {
            $args_list = @()
            if ($Yes) { $args_list += "--yes" }
            if ($ProjectDir) { $args_list += "--project-dir"; $args_list += $ProjectDir }
            bash scripts/automatically_detect_all_installed_coding_agents_and_install_mcp_agent_mail_in_all.sh $args_list
        } else {
            Write-Warn "PowerShell integration script and Bash not found. Cannot run auto-detect integration automatically."
            Write-Info "Please run the server manually:"
            Write-Info "cd $RepoDir; uv run python -m mcp_agent_mail.cli serve-http"
        }
    } finally {
        Pop-Location
    }
}

function Install-CLIStub {
    $stubDir = Join-Path $HOME ".local\bin"
    if (-not (Test-Path $stubDir)) {
        New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
    }
    $stubPath = Join-Path $stubDir "mcp-agent-mail.ps1"
    
    $content = @"
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "║   🚫  MCP Agent Mail is NOT a CLI tool!                                      ║" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "║   It's an MCP (Model Context Protocol) server that provides tools to your   ║" -ForegroundColor Yellow
Write-Host "║   AI coding agent. You should already have access to these tools as part    ║" -ForegroundColor Yellow
Write-Host "║   of your available MCP tools.                                              ║" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "║   ✅ CORRECT USAGE:                                                          ║" -ForegroundColor Yellow
Write-Host "║      Use the MCP tools directly, for example:                               ║" -ForegroundColor Yellow
Write-Host "║        • mcp__mcp-agent-mail__register_agent                                ║" -ForegroundColor Yellow
Write-Host "║        • mcp__mcp-agent-mail__send_message                                  ║" -ForegroundColor Yellow
Write-Host "║        • mcp__mcp-agent-mail__fetch_inbox                                   ║" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "║   ❌ INCORRECT USAGE:                                                        ║" -ForegroundColor Yellow
Write-Host "║      Running shell commands like:                                           ║" -ForegroundColor Yellow
Write-Host "║        • mcp-agent-mail send --to BlueLake ...                              ║" -ForegroundColor Yellow
Write-Host "║        • mcp-agent-mail --help                                              ║" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "║   📚 For documentation, see:                                                 ║" -ForegroundColor Yellow
Write-Host "║      https://github.com/Dicklesworthstone/mcp_agent_mail                    ║" -ForegroundColor Yellow
Write-Host "║                                                                              ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
exit 1
"@
    $content | Set-Content $stubPath
    Write-Ok "Installed helpful CLI stub at $stubPath"
    Record-Summary "CLI stub: installed (catches mistaken CLI usage)"
}

function Install-Alias($name, $cmd) {
    if (-not (Test-Path $PROFILE)) {
        $profileDir = Split-Path $PROFILE
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }
    
    $marker = "# >>> MCP Agent Mail alias $name"
    $endMarker = "# <<< MCP Agent Mail alias"
    $snippet = @"
$marker
function $name { $cmd }
$endMarker
"@
    
    $retryCount = 0
    while ($retryCount -lt 5) {
        try {
            $content = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { $content = "" }
            
            if ($content -match [regex]::Escape($marker)) {
                # Update existing
                $newContent = $content -replace "$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))", $snippet
            } else {
                # Append
                $newContent = $content + "`n" + $snippet
            }
            
            $newContent | Set-Content $PROFILE -ErrorAction Stop
            Write-Ok "Updated '$name' alias in `$PROFILE"
            return
        } catch {
            $retryCount++
            Start-Sleep -Milliseconds (100 * $retryCount)
        }
    }
    Write-Warn "Could not update '$name' alias in `$PROFILE (file locked)"
}

function Ensure-Beads {
    if ($SkipBeads) {
        Write-Warn "-SkipBeads specified; not installing Beads Rust CLI"
        Record-Summary "Beads Rust CLI: skipped (-SkipBeads)"
        return
    }

    if (Need-Cmd "br") {
        $version = br --version 2>$null | Select-Object -First 1
        Write-Ok "Beads Rust CLI ready ($version)"
        Record-Summary "Beads Rust CLI: $version"
        Install-Alias "bd" "br"
        return
    }

    Write-Info "Installing Beads Rust (br) CLI..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Dicklesworthstone/beads_rust/releases/latest"
        $asset = $release.assets | Where-Object { $_.name -match "windows_amd64\.zip$" }
        if ($null -eq $asset) { throw "Could not find Windows asset for Beads Rust" }
        
        $zipUrl = $asset.browser_download_url
        $tempZip = Join-Path $env:TEMP "br.zip"
        $installDir = Join-Path $HOME ".local\bin"
        if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
        
        Write-Info "Downloading Beads Rust from $zipUrl"
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip
        
        Write-Info "Extracting to $installDir"
        Expand-Archive -Path $tempZip -DestinationPath $installDir -Force
        
        # Add to PATH for current session
        if ($env:PATH -notmatch [regex]::Escape($installDir)) {
            $env:PATH = "$installDir;$env:PATH"
        }
        
        # Persist PATH
        $currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($currentPath -notmatch [regex]::Escape($installDir)) {
            [System.Environment]::SetEnvironmentVariable("Path", "$installDir;$currentPath", "User")
            Write-Ok "Added $installDir to User PATH."
        }
        
        $version = br --version 2>$null | Select-Object -First 1
        Write-Ok "Beads Rust CLI installed ($version)"
        Record-Summary "Beads Rust CLI: installed ($version)"
        Install-Alias "bd" "br"
        Remove-Item $tempZip -Force
    } catch {
        Write-Warn "Failed to install Beads Rust automatically: $_"
        Write-Info "You can install it manually from: https://github.com/Dicklesworthstone/beads_rust"
        Record-Summary "Beads Rust CLI: install failed (manual install recommended)"
    }
}

function Ensure-BV {
    if ($SkipBv) {
        Write-Warn "-SkipBv specified; not installing Beads Viewer"
        Record-Summary "Beads Viewer: skipped (-SkipBv)"
        return
    }

    if (Need-Cmd "bv") {
        $version = bv --version 2>$null | Select-Object -First 1
        Write-Ok "Beads Viewer ready ($version)"
        Record-Summary "Beads Viewer: $version"
        return
    }

    Write-Info "Installing Beads Viewer (bv) TUI..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Dicklesworthstone/beads_viewer/releases/latest"
        $asset = $release.assets | Where-Object { $_.name -match "windows_amd64.tar.gz" }
        if ($null -eq $asset) { throw "Could not find Windows asset for Beads Viewer" }
        
        $tarUrl = $asset.browser_download_url
        $tempTar = Join-Path $env:TEMP "bv.tar.gz"
        $installDir = Join-Path $HOME ".local\bin"
        if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
        
        Write-Info "Downloading Beads Viewer from $tarUrl"
        Invoke-WebRequest -Uri $tarUrl -OutFile $tempTar
        
        Write-Info "Extracting to $installDir"
        # Windows 10+ has tar.exe
        Push-Location $installDir
        & tar.exe -xzf $tempTar
        Pop-Location
        
        # Add to PATH for current session
        if ($env:PATH -notmatch [regex]::Escape($installDir)) {
            $env:PATH = "$installDir;$env:PATH"
        }
        
        $version = bv --version 2>$null | Select-Object -First 1
        Write-Ok "Beads Viewer ready ($version)"
        Record-Summary "Beads Viewer: installed ($version)"
        Remove-Item $tempTar -Force
    } catch {
        Write-Warn "Failed to install Beads Viewer automatically: $_"
        Write-Info "You can install it manually from: https://github.com/Dicklesworthstone/beads_viewer"
        Record-Summary "Beads Viewer: install failed (optional)"
    }
}

function Offer-DocBlurbs {
    if ($Yes) {
        Write-Info "Docs helper available anytime via: uv run python -m mcp_agent_mail.cli docs insert-blurbs"
        return
    }

    Write-Host ""
    Write-Host "Would you like to automatically detect your code projects and insert the relevant blurbs for Agent Mail into your AGENTS.md and CLAUDE.md files?"
    Write-Host "You will be able to confirm for each detecting project if you want to do that. Otherwise, just skip that, but be sure to add the blurbs yourself manually for the system to work properly."
    $choice = Read-Host "[y/N]"
    if ($choice -match "^[yY]") {
        Push-Location $RepoDir
        try {
            uv run python -m mcp_agent_mail.cli docs insert-blurbs
        } catch {
            Write-Warn "Docs helper encountered an issue. You can rerun it later with: uv run python -m mcp_agent_mail.cli docs insert-blurbs"
        } finally {
            Pop-Location
        }
    } else {
        Write-Info "Skipping automatic doc updates; remember to add the blurbs manually."
    }
}

function Main {
    if ($StartOnly) {
        Write-Info "-StartOnly specified: skipping clone/setup; starting integration"
        $script:RepoDir = $PWD.Path
        Record-Summary "Repo: existing at $script:RepoDir (-StartOnly)"
        Ensure-Beads
        Ensure-BV
        Install-CLIStub
        $run_cmd = "Push-Location `"$RepoDir`"; .\scripts\run_server_with_token.ps1; Pop-Location"
        Install-Alias "am" $run_cmd
        Configure-Port
        Run-IntegrationAndStart
        Print-Summary
        Offer-DocBlurbs
        return
    }

    Ensure-Uv
    Ensure-Beads
    Ensure-BV
    Ensure-Repo
    Ensure-PythonAndVenv
    Sync-Deps
    Configure-Port
    Install-CLIStub
    
    $run_cmd = "Push-Location `"$RepoDir`"; .\scripts\run_server_with_token.ps1; Pop-Location"
    Install-Alias "am" $run_cmd
    
    Run-IntegrationAndStart
    Print-Summary
    Offer-DocBlurbs

    Write-Host ""
    Write-Ok "All set!"
    Write-Host "Next steps (PowerShell):"
    Write-Host "  am                                    # quick alias to start the server (restart shell to apply)"
    Write-Host "  # or manually:"
    Write-Host "  cd `"$RepoDir`""
    Write-Host "  .venv\Scripts\Activate.ps1"
    Write-Host "  uv run python -m mcp_agent_mail.cli serve-http"
}

Main
