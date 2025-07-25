<#
    Deploy_Velociraptor_Standalone.ps1
    ▸ Downloads latest Velociraptor EXE (or re-uses an existing one)
    ▸ Creates C:\VelociraptorData as the GUI’s datastore
    ▸ Adds an inbound firewall rule for TCP 8889 (netsh fallback)
    ▸ Launches   velociraptor.exe gui --datastore C:\VelociraptorData
    ▸ Waits until the port is listening, then exits

    Logs → %ProgramData%\VelociraptorDeploy\standalone_deploy.log
#>

$ErrorActionPreference = 'Stop'

############  helpers  ###################################################
function Log {
    param([string]$Msg)
    $dir = Join-Path $Env:ProgramData VelociraptorDeploy
    if (-not (Test-Path $dir)) { New-Item -Type Directory $dir -Force | Out-Null }
    ("{0}`t{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) |
    Out-File (Join-Path $dir standalone_deploy.log) -Append -Encoding utf8
    Write-Host $Msg
}

function Require-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'Run this script **as Administrator**.'
    }
}

function Latest-WindowsAsset {
    Log 'Querying GitHub for the latest Velociraptor release …'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/Velocidex/velociraptor/releases/latest' `
        -Headers @{ 'User-Agent' = 'StandaloneVelo' }
    $asset = $rel.assets | Where-Object { $_.name -like '*windows-amd64.exe' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not locate a Windows AMD64 asset in the latest release.' }
    return $asset.browser_download_url
}

function Download-EXE ($Url, $DestEXE) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Log "Downloading $($Url.Split('/')[-1]) …"
    Invoke-WebRequest -Uri $Url -OutFile "$DestEXE.download" -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    Move-Item "$DestEXE.download" $DestEXE -Force
    Log 'Download complete.'
}

function Add-FirewallTCP ($Port) {
    $rule = 'Velociraptor Standalone GUI'

    if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
        Log "Firewall rule '$rule' already exists – skipping."
        return
    }

    if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) {
        try {
            New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $Port 2>$null
            Log "Inbound rule added via New-NetFirewallRule (TCP $Port)."
            return
        }
        catch {}
    }

    # fallback (Server Core, LTSC IoT, Sandbox, etc.)
    $out = netsh advfirewall firewall add rule name="$rule" dir=in action=allow `
        protocol=TCP localport=$Port 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log "Inbound rule added via netsh (TCP $Port)."
    }
    else {
        Log "Warning: netsh failed – add the rule manually if you need remote access.`n$out"
    }
}

function Wait-Port ($Port, $Seconds = 10) {
    1..$Seconds | ForEach-Object {
        Start-Sleep 1
        if (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

############  main  #######################################################
Require-Admin
Log '==== Velociraptor STAND-ALONE deploy started ===='

$InstallDir = 'C:\tools'
$DataStore = 'C:\VelociraptorData'
$GuiPort = 8889

foreach ($p in @($InstallDir, $DataStore)) {
    if (-not (Test-Path $p)) { New-Item -Type Directory $p -Force | Out-Null }
}

$exe = Join-Path $InstallDir velociraptor.exe
if (-not (Test-Path $exe)) {
    $url = Latest-WindowsAsset
    Download-EXE $url $exe
}
else {
    Log "Using existing EXE at $exe"
}

# firewall
Add-FirewallTCP $GuiPort

# launch
Start-Process $exe -ArgumentList "gui --datastore $DataStore" -WorkingDirectory $InstallDir

if (Wait-Port $GuiPort 10) {
    Log "Velociraptor GUI ready → https://127.0.0.1:${GuiPort}  (admin / password)"
    Log '==== Deployment complete ===='
}
else {
    Log "ERROR: Velociraptor did not open port ${GuiPort}. Run manually:`n" +
    "    & `"$exe`" gui --datastore $DataStore -v`n" +
    "and read the console output."
}

