# OpenClaw Windows Node Host Setup
# Installs openclaw and configures per-developer node hosts
# that connect back to each developer's gateway pod via Internal Load Balancer.
# Gateway auth token is fetched from GCP Secret Manager at runtime.

$ErrorActionPreference = "Continue"

# Parse template variables from Terraform
$tlsFingerprint = '${tls_fingerprint}'
$developersJson = '${developers_json}'
$developers = $developersJson | ConvertFrom-Json

# ── Install Node.js ─────────────────────────────────────────────────────────

$nodeVersion = "22.15.0"
$nodeInstaller = "C:\Windows\Temp\node-installer.msi"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Output "Installing Node.js $nodeVersion..."
    $nodeUrl = "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-x64.msi"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeInstaller -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$nodeInstaller`" /qn /norestart" -Wait -NoNewWindow

    # Add Node.js to PATH for this session
    $env:PATH = "C:\Program Files\nodejs;$env:PATH"
    [Environment]::SetEnvironmentVariable("PATH", "C:\Program Files\nodejs;$([Environment]::GetEnvironmentVariable('PATH', 'Machine'))", "Machine")

    Write-Output "Node.js installed: $(node --version)"
} else {
    Write-Output "Node.js already installed: $(node --version)"
}

# ── Install openclaw globally ───────────────────────────────────────────────

Write-Output "Installing/updating openclaw to latest..."
npm install -g openclaw@latest --ignore-scripts 2>&1

# Patch: allow node host to start even if optional extension plugins fail to load.
# The gateway uses throwOnLoadError:false but the node CLI defaults to true.
$globalRoot = (& npm root -g 2>&1).Trim()
$loaderFiles = Get-ChildItem -Path "$globalRoot\openclaw\dist" -Filter "runtime-registry-loader-*.js" -ErrorAction SilentlyContinue
foreach ($loaderFile in $loaderFiles) {
    $content = Get-Content -Path $loaderFile.FullName -Raw
    if ($content -match 'throwOnLoadError: true') {
        $content = $content -replace 'throwOnLoadError: true', 'throwOnLoadError: false'
        Set-Content -Path $loaderFile.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Output "Patched throwOnLoadError in $($loaderFile.Name)"
    }
}

$openclawVer = & "C:\Program Files\nodejs\npx.cmd" openclaw --version 2>&1
Write-Output "openclaw version: $openclawVer"

# ── Fetch gateway token from Secret Manager ─────────────────────────────────

Write-Output "Fetching gateway auth token from Secret Manager..."
$gatewayToken = gcloud secrets versions access latest --secret="openclaw-gateway-token" --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: Failed to fetch gateway token from Secret Manager: $gatewayToken"
    exit 1
}
Write-Output "Gateway token retrieved from Secret Manager."

# Set token as machine-level env var for scheduled tasks
[Environment]::SetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN", $gatewayToken, "Machine")
$env:OPENCLAW_GATEWAY_TOKEN = $gatewayToken


# ── Set up state directory ──────────────────────────────────────────────────

$openclawStateDir = "C:\openclaw\state"
if (-not (Test-Path $openclawStateDir)) {
    New-Item -ItemType Directory -Path $openclawStateDir -Force | Out-Null
}
$env:OPENCLAW_STATE_DIR = "C:\openclaw\state"

# Disable exec approvals on node host (auto-approve all commands)
& "C:\Program Files\nodejs\npx.cmd" openclaw config set tools.exec.security full 2>&1
& "C:\Program Files\nodejs\npx.cmd" openclaw config set tools.exec.ask off 2>&1

# Pre-seed exec-approvals.json in all locations the node host process may use
$execApprovalsContent = '{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}'
$approvalPaths = @(
    "$openclawStateDir",
    "C:\Windows\system32\config\systemprofile\.openclaw",
    "$env:USERPROFILE\.openclaw"
)
foreach ($dir in $approvalPaths) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $eaFile = Join-Path $dir "exec-approvals.json"
    $needsUpdate = $true
    if (Test-Path $eaFile) {
        try {
            $existing = Get-Content $eaFile -Raw | ConvertFrom-Json
            if ($existing.defaults.security -eq "full") { $needsUpdate = $false }
        } catch {}
    }
    if ($needsUpdate) {
        if (Test-Path $eaFile) {
            $existing = Get-Content $eaFile -Raw | ConvertFrom-Json
            $existing | Add-Member -NotePropertyName "defaults" -NotePropertyValue @{security="full";ask="off";askFallback="full"} -Force
            $existing | Add-Member -NotePropertyName "agents" -NotePropertyValue @{main=@{security="full";ask="off"}} -Force
            $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $eaFile -Encoding UTF8
        } else {
            $execApprovalsContent | Set-Content -Path $eaFile -Encoding UTF8
        }
    }
}

# ── Register per-developer node hosts ───────────────────────────────────────

foreach ($devName in $developers.PSObject.Properties.Name) {
    $dev = $developers.$devName
    $taskName = "OpenClaw-Node-$devName"
    $gatewayIp = $dev.gateway_ip

    if (-not $dev.active) {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Output "Removed node host task for inactive developer: $devName"
        }
        continue
    }

    Write-Output "Setting up node host for $devName -> gateway at $${gatewayIp}:18789"

    # Clean stale device identity so the node host re-pairs on every VM restart.
    # This prevents token mismatch when the gateway pod was restarted independently.
    $devStateDir = "C:\openclaw\state\$devName"
    foreach ($cleanDir in @($devStateDir, "C:\Windows\system32\config\systemprofile\.openclaw", "C:\Users\SYSTEM\.openclaw")) {
        foreach ($subDir in @("devices", "identity")) {
            if (Test-Path "$cleanDir\$subDir") {
                Remove-Item -Recurse -Force "$cleanDir\$subDir" -ErrorAction SilentlyContinue
                Write-Output "Cleaned stale $subDir from $cleanDir"
            }
        }
    }

    # Create wrapper script for each developer's node host
    $scriptDir = "C:\openclaw\nodes"
    if (-not (Test-Path $scriptDir)) {
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    }

    $scriptPath = Join-Path $scriptDir "$devName-node.ps1"
    @"
# OpenClaw node host for developer: $devName
# Auth token is read from OPENCLAW_GATEWAY_TOKEN env var (fetched from Secret Manager)
`$env:PATH = "C:\Program Files\nodejs;C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin;`$env:PATH"
`$env:OPENCLAW_STATE_DIR = "C:\openclaw\state\$devName"
if (-not (Test-Path `$env:OPENCLAW_STATE_DIR)) { New-Item -ItemType Directory -Path `$env:OPENCLAW_STATE_DIR -Force | Out-Null }

# Re-fetch token from Secret Manager on each restart (supports rotation)
`$token = gcloud secrets versions access latest --secret="openclaw-gateway-token" --quiet 2>&1
if (`$LASTEXITCODE -eq 0) {
    `$env:OPENCLAW_GATEWAY_TOKEN = `$token
} else {
    Write-Output "WARNING: Could not refresh token, using cached value"
    `$env:OPENCLAW_GATEWAY_TOKEN = [Environment]::GetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN", "Machine")
}
while (`$true) {
    # Patch exec-approvals.json after node host creates it (background, 15s delay)
    Start-Job -ScriptBlock {
        Start-Sleep -Seconds 15
        `$locations = @(
            `$env:OPENCLAW_STATE_DIR,
            "C:\Windows\system32\config\systemprofile\.openclaw",
            "C:\openclaw\state"
        )
        `$patch = '{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}'
        foreach (`$dir in `$locations) {
            if (-not `$dir) { continue }
            `$f = Join-Path `$dir "exec-approvals.json"
            if (Test-Path `$f) {
                try {
                    `$obj = Get-Content `$f -Raw | ConvertFrom-Json
                    if (`$obj.defaults.security -ne "full") {
                        `$merged = `$patch | ConvertFrom-Json
                        if (`$obj.socket) { `$merged | Add-Member -NotePropertyName "socket" -NotePropertyValue `$obj.socket -Force }
                        `$merged | ConvertTo-Json -Depth 5 | Set-Content -Path `$f -Encoding UTF8
                        Write-Output "Patched `$f"
                    }
                } catch {}
            } else {
                if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
                `$patch | Set-Content -Path `$f -Encoding UTF8
                Write-Output "Created `$f"
            }
        }
    } | Out-Null
    Write-Output "Starting openclaw node host for $devName (gateway: $${gatewayIp}:18789, TLS)..."
    & "C:\Program Files\nodejs\npx.cmd" openclaw node run --host $gatewayIp --port 18789 --tls --tls-fingerprint $tlsFingerprint --display-name "windows-$devName"
    Write-Output "Node host exited, restarting in 10 seconds..."
    Start-Sleep -Seconds 10
}
"@ | Set-Content -Path $scriptPath -Encoding UTF8

    # Create/update scheduled task
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Days 365)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    # Start immediately
    Start-ScheduledTask -TaskName $taskName
    Write-Output "Node host started for $devName (task: $taskName)"
}

Write-Output "OpenClaw Windows node host setup complete."
