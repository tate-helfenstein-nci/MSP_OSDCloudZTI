<#
.SYNOPSIS
  OSDCloud ZTI Master Script - MSP Multi-Tenant (ISO / PXE Ready)
  Deploys Windows, then branches Autopilot or Non-Autopilot per tenant config.

.DESCRIPTION
  Phase 1: Pre-flight hardware checks (TPM, Secure Boot, RAM, Disk)
  Phase 2: Load Tenants.json (URL > WinPE baked-in > USB fallback) + tenant selection
  Phase 3: Update OSD/OSDCloud PowerShell modules
  Phase 4: OSDCloud ZTI Windows deployment
  Phase 5: Autopilot hash upload (Graph v1.0) OR Non-Autopilot local admin + hostname
  Phase 6: Copy logs to offline OS + reboot

.NOTES
  Autopilot tenants require Entra App Registration with:
    DeviceManagementServiceConfig.ReadWrite.All (Application)

  Config priority: URL > X:\OSDCloud baked-in > USB drive

.PARAMETER TenantKey
  Skip the menu and select a tenant directly by key.

.PARAMETER GroupTagOverride
  Override the tenant's default Autopilot group tag.

.PARAMETER ComputerName
  Override auto-generated hostname (non-Autopilot path).

.PARAMETER SkipAutopilot
  Force non-Autopilot path regardless of tenant config.

.PARAMETER PromptForPassphrase
  Prompt to decrypt EncryptedSecret or EncryptedPassword fields.

.PARAMETER ConfigUrl
  Override the default Tenants.json download URL.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantKey = "",

    [Parameter(Mandatory = $false)]
    [string]$GroupTagOverride = "",

    [Parameter(Mandatory = $false)]
    [string]$ComputerName = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipAutopilot,

    [Parameter(Mandatory = $false)]
    [switch]$PromptForPassphrase,

    [Parameter(Mandatory = $false)]
    [string]$ConfigUrl = "https://github.com/tate-helfenstein-nci/MSP_OSDCloudZTI/blob/main/Tenants.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# LOGGING
# ============================================================
#region Logging
function Get-LogPath {
    $p = 'X:\OSDCloud\Logs'
    if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
    return (Join-Path $p 'OSDCloudZTI.log')
}
$LogFile = Get-LogPath

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Tee-Object -FilePath $LogFile -Append
}
#endregion

# ============================================================
# BANNER
# ============================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "   OSDCloud ZTI - MSP Multi-Tenant Deploy"    -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "=== OSDCloud ZTI Master Script starting ==="

# ============================================================
# SAFETY CHECK
# ============================================================
if ($env:SystemDrive -ne 'X:') {
    Write-Host "ERROR: This script must run from WinPE (X:\)" -ForegroundColor Red
    Write-Log "Not running in WinPE. Exiting." "ERROR"
    exit 1
}

# ============================================================
# DISPLAY RESOLUTION
# ============================================================
try {
    Set-DisRes 1600
} catch {
    Write-Log "Could not set display resolution." "WARN"
}

# ============================================================
# HELPER: DECRYPT PORTABLE SECRET
# ============================================================
#region Secret Decryption
function Unprotect-PortableSecret {
    param(
        [string]$EncryptedValue
    )
    $pass = Read-Host "Enter decryption passphrase" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
    try {
        $passPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $keyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($passPlain)
    )
    $secure = ConvertTo-SecureString $EncryptedValue -Key $keyBytes
    $bstrOut = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrOut)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrOut)
    }
}
#endregion

# ============================================================
# PHASE 1: PRE-FLIGHT CHECKS
# ============================================================
#region Phase 1
Write-Host ""
Write-Host "[Phase 1] Pre-flight hardware checks..." -ForegroundColor Yellow
Write-Log "Phase 1: Pre-flight checks"

$preflight = $true

# ---- TPM ----
$tpm = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm `
    -ClassName Win32_Tpm -ErrorAction SilentlyContinue
if ($tpm -and $tpm.IsEnabled_InitialValue) {
    Write-Host "  [PASS] TPM present and enabled" -ForegroundColor Green
    Write-Log "TPM: Present and enabled"
} else {
    Write-Host "  [WARN] TPM not detected or not enabled" -ForegroundColor Yellow
    Write-Log "TPM: Not detected or disabled" "WARN"
}

# ---- Secure Boot ----
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if ($sb) {
        Write-Host "  [PASS] Secure Boot enabled" -ForegroundColor Green
        Write-Log "Secure Boot: Enabled"
    } else {
        Write-Host "  [WARN] Secure Boot disabled" -ForegroundColor Yellow
        Write-Log "Secure Boot: Disabled" "WARN"
    }
} catch {
    Write-Host "  [WARN] Could not query Secure Boot" -ForegroundColor Yellow
    Write-Log "Secure Boot: Query failed" "WARN"
}

# ---- RAM ----
$ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($ramGB -ge 4) {
    Write-Host "  [PASS] RAM: ${ramGB} GB" -ForegroundColor Green
    Write-Log "RAM: ${ramGB} GB"
} else {
    Write-Host "  [FAIL] RAM: ${ramGB} GB (minimum 4 GB)" -ForegroundColor Red
    Write-Log "RAM: ${ramGB} GB - below minimum" "ERROR"
    $preflight = $false
}

# ---- Disk ----
$disk = Get-Disk | Where-Object { $_.BusType -ne 'USB' } |
    Sort-Object Size -Descending | Select-Object -First 1
if ($disk) {
    $diskGB = [Math]::Round($disk.Size / 1GB, 0)
    if ($diskGB -ge 64) {
        Write-Host "  [PASS] Disk: ${diskGB} GB ($($disk.FriendlyName))" -ForegroundColor Green
        Write-Log "Disk: ${diskGB} GB - $($disk.FriendlyName)"
    } else {
        Write-Host "  [FAIL] Disk: ${diskGB} GB - minimum 64 GB" -ForegroundColor Red
        Write-Log "Disk: ${diskGB} GB - below minimum" "ERROR"
        $preflight = $false
    }
} else {
    Write-Host "  [FAIL] No internal disk found" -ForegroundColor Red
    Write-Log "Disk: Not found" "ERROR"
    $preflight = $false
}

if (-not $preflight) {
    Write-Host ""
    Write-Host "Pre-flight FAILED. Deployment cannot continue." -ForegroundColor Red
    Write-Log "Pre-flight failed. Halting." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "  Pre-flight passed." -ForegroundColor Green
Write-Host ""
#endregion

# ============================================================
# PHASE 2: LOAD CONFIG + SELECT TENANT
# ============================================================
#region Phase 2
Write-Host "[Phase 2] Loading tenant configuration..." -ForegroundColor Yellow
Write-Log "Phase 2: Tenant selection"

$configRaw = $null

# --- Attempt 1: Download from URL ---
if ($ConfigUrl -and $ConfigUrl -notmatch 'yourstorageaccount') {
    try {
        Write-Log "Attempting config download from $ConfigUrl"
        $webContent = Invoke-RestMethod -Uri $ConfigUrl -TimeoutSec 15
        if ($webContent -is [string]) {
            $configRaw = $webContent | ConvertFrom-Json
        } else {
            $configRaw = $webContent
        }
        Write-Host "  Config loaded from URL" -ForegroundColor Green
        Write-Log "Config loaded from URL."
    } catch {
        Write-Log "URL config download failed: $($_.Exception.Message)" "WARN"
    }
}

# --- Attempt 2: Baked into WinPE ---
if (-not $configRaw) {
    $bakedPaths = @(
        "X:\OSDCloud\Config\Scripts\Tenants.json",
        "X:\OSDCloud\Config\Tenants.json",
        "X:\OSDCloud\Tenants.json"
    )
    foreach ($bp in $bakedPaths) {
        if (Test-Path $bp) {
            $configRaw = Get-Content $bp -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "  Config loaded from WinPE: $bp" -ForegroundColor Green
            Write-Log "Config loaded from baked-in path: $bp"
            break
        }
    }
}

# --- Attempt 3: Attached USB fallback ---
if (-not $configRaw) {
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem | Select-Object -Expand Name)) {
        $usbPaths = @(
            "$drv`:\OSDCloud\Config\Tenants.json",
            "$drv`:\OSDCloud\Scripts\Tenants.json",
            "$drv`:\Tenants.json"
        )
        foreach ($up in $usbPaths) {
            if (Test-Path $up) {
                $configRaw = Get-Content $up -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-Host "  Config loaded from USB: $up" -ForegroundColor Green
                Write-Log "Config loaded from USB: $up"
                break
            }
        }
        if ($configRaw) { break }
    }
}

# --- Fail ---
if (-not $configRaw -or -not $configRaw.Tenants) {
    Write-Host "  ERROR: Tenants.json not found (URL, WinPE, or USB)." -ForegroundColor Red
    Write-Log "Tenants.json not found anywhere." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

$tenants = @($configRaw.Tenants)
if ($tenants.Count -lt 1) {
    Write-Host "  ERROR: No tenants defined in config." -ForegroundColor Red
    Write-Log "No tenants in config." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# ---- Device serial ----
$serial = ""
try { $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim() } catch {}
Write-Log "Device serial: $serial"

# ---- Tenant selection ----
$tenant = $null

# By parameter
if ($TenantKey) {
    $tenant = $tenants | Where-Object { $_.TenantKey -eq $TenantKey } | Select-Object -First 1
    if (-not $tenant) {
        Write-Host "  ERROR: TenantKey '$TenantKey' not found." -ForegroundColor Red
        Write-Log "TenantKey '$TenantKey' not found." "ERROR"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# By serial prefix
if (-not $tenant -and $serial) {
    foreach ($t in $tenants) {
        if ($t.SerialPrefixMatch) {
            foreach ($p in @($t.SerialPrefixMatch)) {
                if ($serial.ToUpper().StartsWith($p.ToUpper())) {
                    $tenant = $t
                    break
                }
            }
        }
        if ($tenant) { break }
    }
    if ($tenant) {
        Write-Log "Tenant auto-matched by serial prefix."
    }
}

# Interactive menu
if (-not $tenant) {
    Write-Host ""
    Write-Host "  Select target tenant:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        $ap = if ($tenants[$i].UseAutopilot -eq $false) { " [No Autopilot]" } else { "" }
        Write-Host ("    [{0}] {1} ({2}){3}" -f ($i + 1), $tenants[$i].DisplayName, $tenants[$i].TenantKey, $ap)
    }
    Write-Host ""
    $choice = Read-Host "  Enter number"
    if (-not ($choice -as [int])) {
        Write-Host "  Invalid selection." -ForegroundColor Red
        exit 1
    }
    $idx = ([int]$choice) - 1
    if ($idx -lt 0 -or $idx -ge $tenants.Count) {
        Write-Host "  Selection out of range." -ForegroundColor Red
        exit 1
    }
    $tenant = $tenants[$idx]
}

Write-Host "  Selected: $($tenant.DisplayName)" -ForegroundColor Green
Write-Log "Tenant selected: $($tenant.DisplayName) ($($tenant.TenantKey))"
Write-Host ""
#endregion

# ============================================================
# PHASE 3: UPDATE OSD MODULES
# ============================================================
#region Phase 3
Write-Host "[Phase 3] Updating OSD modules..." -ForegroundColor Yellow
Write-Log "Phase 3: Module update"

try {
    Install-Module OSD -Force -SkipPublisherCheck -ErrorAction Stop
    Import-Module OSD -Force
    Write-Log "OSD module loaded."
} catch {
    Write-Log "OSD module update failed: $($_.Exception.Message)" "WARN"
    try { Import-Module OSD -Force -ErrorAction Stop } catch {}
}

try {
    Install-Module OSDCloud -Force -SkipPublisherCheck -ErrorAction Stop
    Import-Module OSDCloud -Force
    Write-Log "OSDCloud module loaded."
} catch {
    Write-Log "OSDCloud module update failed: $($_.Exception.Message)" "WARN"
    try { Import-Module OSDCloud -Force -ErrorAction Stop } catch {}
}

Write-Host "  Modules ready." -ForegroundColor Green
Write-Host ""
#endregion

# ============================================================
# PHASE 4: OSDCloud OS DEPLOYMENT
# ============================================================
#region Phase 4
Write-Host "[Phase 4] Starting Windows deployment (ZTI)..." -ForegroundColor Yellow
Write-Log "Phase 4: OSDCloud OS deployment"

Start-OSDCloud `
    -OSName 'Windows 11' `
    -OSEdition Enterprise `
    -OSLicense Volume `
    -OSLanguage en-us `
    -ZTI `
    -ClearDisk

Write-Log "OSDCloud deployment completed."
Write-Host "  OS deployment complete." -ForegroundColor Green
Write-Host ""
#endregion

# ============================================================
# PHASE 5: POST-DEPLOY -- AUTOPILOT or NON-AUTOPILOT
# ============================================================
#region Phase 5
Write-Host "[Phase 5] Post-deployment provisioning..." -ForegroundColor Yellow
Write-Log "Phase 5: Post-deploy provisioning"

# ---- Determine path ----
$useAutopilot = $true

if ($SkipAutopilot) {
    $useAutopilot = $false
    Write-Log "Autopilot skipped via -SkipAutopilot"
} elseif ($null -ne $tenant.UseAutopilot -and $tenant.UseAutopilot -eq $false) {
    $useAutopilot = $false
    Write-Log "Autopilot skipped per tenant config"
}

# ----------------------------------------------------------
# NON-AUTOPILOT PATH
# ----------------------------------------------------------
if (-not $useAutopilot) {

    Write-Host "  Path: Non-Autopilot" -ForegroundColor Yellow
    Write-Log "Executing non-Autopilot path"

    # ---- Find offline Windows drive ----
    $osDrive = $null
    foreach ($letter in @('C', 'D', 'E', 'W')) {
        if (Test-Path "${letter}:\Windows\System32\config\SYSTEM") {
            $osDrive = "${letter}:"
            break
        }
    }
    if (-not $osDrive) {
        Write-Log "Offline Windows drive not found." "ERROR"
        throw "Offline Windows installation not found."
    }
    Write-Log "Offline OS drive: $osDrive"

    # ---- 1. Local Admin via Unattend.xml ----
    $adminUser = $null
    if ($tenant.LocalAdmin) {
        $adminUser = $tenant.LocalAdmin.Username
        $adminPass = $tenant.LocalAdmin.PlainPassword

        # Encrypted password support
        if ($tenant.LocalAdmin.EncryptedPassword -and
            $tenant.LocalAdmin.EncryptedPassword.Trim().Length -gt 0 -and
            $PromptForPassphrase) {
            Write-Host "  Decrypting local admin password..." -ForegroundColor Yellow
            $adminPass = Unprotect-PortableSecret -EncryptedValue $tenant.LocalAdmin.EncryptedPassword
        }

        if ($adminUser -and $adminPass) {
            Write-Log "Creating local admin: $adminUser"

            $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$adminUser</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$adminPass</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
            $pantherPath = "$osDrive\Windows\Panther"
            if (-not (Test-Path $pantherPath)) {
                New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
            }
            $unattendXml | Out-File -FilePath "$pantherPath\unattend.xml" -Encoding UTF8 -Force
            Write-Log "Unattend.xml written to $pantherPath\unattend.xml"
        }
    }

    # ---- 2. Computer Name ----
    $newName = ""
    if ($ComputerName) {
        $newName = $ComputerName
    } elseif ($tenant.ComputerNamePrefix -and $serial) {
        $suffix = $serial
        if ($serial.Length -gt 7) { $suffix = $serial.Substring($serial.Length - 7) }
        $newName = "$($tenant.ComputerNamePrefix)-$suffix"
    }

    if ($newName) {
        if ($newName.Length -gt 15) { $newName = $newName.Substring(0, 15) }
        Write-Log "Setting computer name: $newName"

        $systemHive = "$osDrive\Windows\System32\config\SYSTEM"
        & reg load "HKLM\OfflineSYSTEM" $systemHive 2>$null

        & reg add "HKLM\OfflineSYSTEM\ControlSet001\Control\ComputerName\ComputerName" `
            /v ComputerName /t REG_SZ /d $newName /f | Out-Null
        & reg add "HKLM\OfflineSYSTEM\ControlSet001\Services\Tcpip\Parameters" `
            /v "NV Hostname" /t REG_SZ /d $newName /f | Out-Null
        & reg add "HKLM\OfflineSYSTEM\ControlSet001\Services\Tcpip\Parameters" `
            /v Hostname /t REG_SZ /d $newName /f | Out-Null

        & reg unload "HKLM\OfflineSYSTEM" 2>$null
        Write-Log "Computer name set to: $newName"
    }

    # ---- Summary ----
    Write-Host ""
    Write-Host "  Non-Autopilot provisioning complete" -ForegroundColor Green
    if ($newName)   { Write-Host "     Computer Name : $newName" }
    if ($adminUser) { Write-Host "     Local Admin   : $adminUser" }
    Write-Log "Non-Autopilot path complete."

# ----------------------------------------------------------
# AUTOPILOT PATH
# ----------------------------------------------------------
} else {

    Write-Host "  Path: Autopilot" -ForegroundColor Cyan
    Write-Log "Executing Autopilot path"

    # ---- Validate tenant config ----
    if (-not $tenant.TenantId -or -not $tenant.ClientId) {
        Write-Log "Tenant missing TenantId or ClientId." "ERROR"
        throw "Autopilot tenant config incomplete (TenantId/ClientId required)."
    }

    # ---- Resolve secret ----
    $clientSecret = ""
    if ($tenant.ClientSecret -and $tenant.ClientSecret.Trim().Length -gt 0) {
        $clientSecret = $tenant.ClientSecret
    } elseif ($tenant.EncryptedSecret -and $tenant.EncryptedSecret.Trim().Length -gt 0 -and $PromptForPassphrase) {
        Write-Host "  Decrypting tenant secret..." -ForegroundColor Yellow
        $clientSecret = Unprotect-PortableSecret -EncryptedValue $tenant.EncryptedSecret
    } else {
        throw "No secret available for Autopilot tenant '$($tenant.TenantKey)'."
    }

    # ---- Collect hardware hash ----
    Write-Log "Collecting Autopilot hardware hash..."
    $session = New-CimSession
    $devDetail = Get-CimInstance -CimSession $session `
        -Namespace root/cimv2/mdm/dmmap `
        -ClassName MDM_DevDetail_Ext01 `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $devDetail) {
        throw "Could not read hardware hash (MDM_DevDetail_Ext01)."
    }
    $hashB64 = $devDetail.DeviceHardwareData
    Write-Log "Hash captured (base64 length: $($hashB64.Length))"

    # ---- Graph token (client_credentials) ----
    Write-Log "Requesting Graph token for tenant $($tenant.TenantId)..."
    $tokenBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $tenant.ClientId
        client_secret = $clientSecret
    }
    $tokenResp = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$($tenant.TenantId)/oauth2/v2.0/token" `
        -Body $tokenBody `
        -ContentType "application/x-www-form-urlencoded"
    Write-Log "Graph token acquired."

    $graphHeaders = @{
        Authorization  = "Bearer $($tokenResp.access_token)"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }

    # ---- Build payload ----
    $groupTag = if ($GroupTagOverride) { $GroupTagOverride } else { $tenant.DefaultGroupTag }
    Write-Log "GroupTag: $groupTag"

    $payload = @{
        "@odata.type"      = "#microsoft.graph.importedWindowsAutopilotDeviceIdentity"
        groupTag           = $groupTag
        serialNumber       = $serial
        hardwareIdentifier = $hashB64
    } | ConvertTo-Json -Depth 6

    # ---- Upload with retry ----
    $graphUri = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities"
    $uploaded = $false
    $result   = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Write-Log "Graph upload attempt $attempt/5..."
            $result = Invoke-RestMethod -Method POST `
                -Uri $graphUri `
                -Headers $graphHeaders `
                -Body $payload
            $uploaded = $true
            break
        } catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt 5) {
                $sleep = [Math]::Min(60, [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0 -Maximum 3))
                Write-Log "Graph failed (HTTP $status). Retrying in ${sleep}s..." "WARN"
                Start-Sleep -Seconds $sleep
            } else {
                throw
            }
        }
    }

    if ($uploaded) {
        Write-Host ""
        Write-Host "  Autopilot hash uploaded successfully" -ForegroundColor Green
        Write-Host "     Imported ID : $($result.id)"
        Write-Host "     GroupTag    : $groupTag"
        Write-Host "     Serial      : $serial"
        Write-Log "Autopilot upload complete. ID: $($result.id)"
    } else {
        Write-Host "  Autopilot hash upload failed after 5 attempts." -ForegroundColor Red
        Write-Log "Autopilot upload failed after all retries." "ERROR"
    }
}
#endregion

# ============================================================
# PHASE 6: COPY LOGS + REBOOT
# ============================================================
#region Phase 6
Write-Host ""
Write-Host "[Phase 6] Finalizing..." -ForegroundColor Yellow
Write-Log "Phase 6: Finalize and reboot"

# ---- Copy logs to offline OS ----
$osDriveForLogs = $null
foreach ($letter in @('C', 'D', 'E', 'W')) {
    if (Test-Path "${letter}:\Windows") {
        $osDriveForLogs = "${letter}:"
        break
    }
}
if ($osDriveForLogs) {
    $destLogs = "$osDriveForLogs\OSDCloud\Logs"
    if (-not (Test-Path $destLogs)) {
        New-Item -Path $destLogs -ItemType Directory -Force | Out-Null
    }
    Copy-Item "X:\OSDCloud\Logs\*" -Destination $destLogs -Force -ErrorAction SilentlyContinue
    Write-Log "Logs copied to $destLogs"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "   Deployment Complete - Rebooting in 10s"     -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Log "=== OSDCloud ZTI complete. Rebooting. ==="

Start-Sleep -Seconds 10
Restart-Computer -Force
#endregion
