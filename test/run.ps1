# =============================================================================
# Test runner for opencode-with-claude plugin (PowerShell version)
#
# Builds the plugin, sets up a local plugin directory, and launches OpenCode
# so you can verify the plugin works end-to-end.
#
# Uses the .opencode/plugins/ local loading mechanism (no npm link needed).
#
# Usage:
#   .\test\run.ps1          # Build and launch OpenCode with plugin
#   .\test\run.ps1 -Clean   # Remove build artifacts
# =============================================================================

param([switch]$Clean)

$ErrorActionPreference = "Stop"

$GREEN = "`e[32m"
$BLUE = "`e[34m"
$RED = "`e[31m"
$NC = "`e[0m"

function Info($msg) {
    Write-Host "${BLUE}[test]${NC} $msg"
}

function Ok($msg) {
    Write-Host "${GREEN}[test]${NC} $msg"
}

function Fail($msg) {
    Write-Host "${RED}[test]${NC} $msg"
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = Split-Path -Parent $ScriptDir

# --- Clean ---
if ($Clean) {
    Info "Cleaning up..."
    Remove-Item "$PluginDir/dist" -Recurse -Force -ErrorAction SilentlyContinue
    Ok "Cleaned. dist/ deleted."
    exit 0
}

# --- Preflight ---
try {
    $null = Get-Command opencode -ErrorAction Stop
} catch {
    Fail "OpenCode not found. Run: npm install -g opencode-ai"
}

try {
    $null = Get-Command claude -ErrorAction Stop
} catch {
    Fail "Claude CLI not found. Run: npm install -g @anthropic-ai/claude-code"
}

# --- Check auth ---
Info "Checking Claude authentication..."
$authStatus = & claude auth status 2>&1 | Out-String
if ($authStatus -notmatch '"loggedIn":\s*true') {
    Fail "Claude not authenticated. Run: claude login"
}
Ok "Claude authenticated"

# --- Install deps ---
Info "Installing plugin dependencies..."
Push-Location $PluginDir

# Try pnpm first (better Windows support), fall back to npm
$pkgMgr = if (Get-Command pnpm -ErrorAction SilentlyContinue) { "pnpm" } else { "npm" }
& $pkgMgr install --silent 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "($pkgMgr install warning - Windows file locking. Continuing with existing build...)"
}
Pop-Location

# --- Build ---
Info "Building plugin..."
Push-Location $PluginDir
npm run build
if ($LASTEXITCODE -ne 0) { Fail "npm run build failed" }
Pop-Location
Ok "Build complete"

# --- Set up test workspace ---
$WorkDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("opencode-test-$(Get-Random)")) | Select-Object -ExpandProperty FullName
Info "Test workspace: $WorkDir"

# Cleanup function
function Cleanup {
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Copy opencode.json
if (-not (Test-Path "$ScriptDir/opencode.json")) {
    Fail "opencode.json not found at $ScriptDir/opencode.json"
}
Copy-Item "$ScriptDir/opencode.json" "$WorkDir/opencode.json" -ErrorAction Stop

# Set up .opencode/plugins/ with symlink to built plugin
$pluginsDir = "$WorkDir/.opencode/plugins"
New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null

# Copy plugin file (symlink requires admin)
$sourceFile = "$PluginDir/dist/index.js"
$symlinkPath = "$pluginsDir/claude-proxy.js"
Copy-Item $sourceFile $symlinkPath -Force -ErrorAction Stop

# Add package.json for the plugin's runtime dependency
@{} | ConvertTo-Json | Set-Content "$WorkDir/.opencode/package.json" -ErrorAction Stop

# --- Launch OpenCode ---
Info "Launching OpenCode with local plugin..."
Info "Plugin: $PluginDir/dist/index.js -> .opencode/plugins/claude-proxy.js"
Info "The plugin will start its own proxy on an OS-assigned port."
Info ""

try {
    Push-Location $WorkDir
    & opencode
} finally {
    Pop-Location
    Cleanup
}
