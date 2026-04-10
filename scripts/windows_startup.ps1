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
    Write-Output "ERROR: Failed to fetch gateway token from Secret Manager. Check IAM permissions and secret existence."
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

    # Create log directory for Ops Agent to pick up
    $logDir = "C:\openclaw\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $scriptPath = Join-Path $scriptDir "$devName-node.ps1"
    @"
# OpenClaw node host for developer: $devName
# Auth token is read from OPENCLAW_GATEWAY_TOKEN env var (fetched from Secret Manager)
`$env:PATH = "C:\Program Files\nodejs;C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin;`$env:PATH"
`$env:OPENCLAW_STATE_DIR = "C:\openclaw\state\$devName"
if (-not (Test-Path `$env:OPENCLAW_STATE_DIR)) { New-Item -ItemType Directory -Path `$env:OPENCLAW_STATE_DIR -Force | Out-Null }

# Pre-seed exec-approvals.json in ALL possible locations before node host starts
`$eaContent = '{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}'
`$eaDirs = @(
    `$env:OPENCLAW_STATE_DIR,
    "C:\openclaw\state",
    "C:\Windows\system32\config\systemprofile\.openclaw",
    (Join-Path `$env:SYSTEMROOT "system32\config\systemprofile\.openclaw"),
    "C:\Users\Default\.openclaw"
)
# Also discover USERPROFILE at runtime (may differ for SYSTEM)
if (`$env:USERPROFILE) { `$eaDirs += Join-Path `$env:USERPROFILE ".openclaw" }
if (`$env:APPDATA) { `$eaDirs += Join-Path `$env:APPDATA "openclaw" }
`$eaDirs = `$eaDirs | Select-Object -Unique
foreach (`$d in `$eaDirs) {
    if (-not `$d) { continue }
    if (-not (Test-Path `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }
    `$eaContent | Set-Content -Path (Join-Path `$d "exec-approvals.json") -Encoding UTF8
}
# Also set via CLI for the current OPENCLAW_STATE_DIR
& "C:\Program Files\nodejs\npx.cmd" openclaw approvals set (Join-Path `$env:OPENCLAW_STATE_DIR "exec-approvals.json") 2>&1 | Out-Null

# Re-fetch token from Secret Manager on each restart (supports rotation)
`$token = gcloud secrets versions access latest --secret="openclaw-gateway-token" --quiet 2>&1
if (`$LASTEXITCODE -eq 0) {
    `$env:OPENCLAW_GATEWAY_TOKEN = `$token
} else {
    Write-Output "WARNING: Could not refresh token, using cached value"
    `$env:OPENCLAW_GATEWAY_TOKEN = [Environment]::GetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN", "Machine")
}
`$logFile = "C:\openclaw\logs\$devName-node.log"
while (`$true) {
    `$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "`$ts Starting openclaw node host for $devName (gateway: $${gatewayIp}:18789, TLS)..." | Tee-Object -FilePath `$logFile -Append
    & "C:\Program Files\nodejs\npx.cmd" openclaw node run --host $gatewayIp --port 18789 --tls --tls-fingerprint $tlsFingerprint --display-name "windows-$devName" 2>&1 | Tee-Object -FilePath `$logFile -Append
    `$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "`$ts Node host exited, restarting in 10 seconds..." | Tee-Object -FilePath `$logFile -Append
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

# ── Install Google Cloud Ops Agent for log shipping ────────────────────────

$opsAgentService = Get-Service -Name "google-cloud-ops-agent" -ErrorAction SilentlyContinue
if (-not $opsAgentService) {
    Write-Output "Installing Google Cloud Ops Agent..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $opsAgentInstaller = "C:\Windows\Temp\ops-agent-installer.ps1"
    Invoke-WebRequest -Uri "https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.ps1" -OutFile $opsAgentInstaller -UseBasicParsing
    & powershell.exe -ExecutionPolicy Bypass -File $opsAgentInstaller -AlsoInstall

    # Configure Ops Agent to collect openclaw scheduled task logs from Windows Event Log
    $opsAgentConfig = @"
logging:
  receivers:
    openclaw_events:
      type: windows_event_log
      channels:
        - Application
        - System
      receiver_version: 2
    openclaw_task_logs:
      type: files
      include_paths:
        - C:\openclaw\logs\*.log
  service:
    pipelines:
      openclaw_pipeline:
        receivers:
          - openclaw_events
          - openclaw_task_logs
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      default_pipeline:
        receivers:
          - hostmetrics
"@
    $opsAgentConfig | Set-Content -Path "C:\Program Files\Google\Cloud Operations\Ops Agent\config\config.yaml" -Encoding UTF8
    Restart-Service -Name "google-cloud-ops-agent" -Force
    Write-Output "Ops Agent installed and configured."
} else {
    Write-Output "Ops Agent already running."
}

Write-Output "OpenClaw Windows node host setup complete."
