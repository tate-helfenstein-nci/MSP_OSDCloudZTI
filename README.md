# OSDCloud ZTI — MSP Multi-Tenant Deployment

> **One USB. One ISO. One PXE boot. Every customer.**

This toolkit deploys Windows 11 via OSDCloud in a fully zero-touch workflow,
then automatically handles Autopilot hash upload or non-Autopilot local
provisioning based on the selected customer tenant.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [What You Need](#what-you-need)
3. [Folder Structure](#folder-structure)
4. [Tenants.json Reference](#tenantsjson-reference)
5. [Building the ISO](#building-the-iso)
6. [PXE Setup](#pxe-setup)
7. [USB Boot (Alternative)](#usb-boot-alternative)
8. [Deploying a Device](#deploying-a-device)
9. [What Happens at Each Phase](#what-happens-at-each-phase)
10. [After Reboot](#after-reboot)
11. [Log Files](#log-files)
12. [Updating Tenants Without Rebuilding the ISO](#updating-tenants-without-rebuilding-the-iso)
13. [Encrypting Secrets](#encrypting-secrets)
14. [Troubleshooting](#troubleshooting)
15. [FAQ](#faq)
16. [Security Notes](#security-notes)

---

## How It Works

The deployment follows six phases in sequence:

| Step | What Happens |
|------|--------------|
| **Boot** | Device PXE or USB boots into WinPE |
| **Phase 1** | Pre-flight hardware checks (TPM, Secure Boot, RAM, Disk) |
| **Phase 2** | Tenant config loaded and customer selected |
| **Phase 3** | OSD / OSDCloud PowerShell modules updated |
| **Phase 4** | Windows 11 deployed via OSDCloud (ZTI, disk wiped) |
| **Phase 5a** | _Autopilot tenant:_ Hardware hash uploaded to Microsoft Graph |
| **Phase 5b** | _Non-Autopilot tenant:_ Local admin and computer name injected |
| **Phase 6** | Logs copied to OS drive, device reboots |
| **Post-boot** | OOBE starts — Autopilot activates or local admin desktop loads |

**You do not need to touch the device after boot** unless tenant selection
requires the interactive menu.

---

## What You Need

### Build Machine Requirements

| Requirement | Details |
|-------------|---------|
| Admin workstation | Windows 10 or 11 with internet access |
| Windows ADK | Matching your target OS generation |
| Windows PE Add-on for ADK | Required for WinPE image creation |
| PowerShell 5.1+ | Ships with Windows 10/11 |
| OSD + OSDCloud modules | `Install-Module OSD, OSDCloud -Force` |
| PXE server (for PXE boot) | iVentoy (recommended) or WDS |

### Per Autopilot Tenant

Each Autopilot customer tenant needs an **Entra ID App Registration** with:

- **Microsoft Graph** application permission: `DeviceManagementServiceConfig.ReadWrite.All`
- **Admin consent** granted
- A **client secret** — store the value in `Tenants.json`

> Non-Autopilot tenants do **not** need an App Registration, TenantId, or ClientId.

---

## Folder Structure

### Build Machine

```text
D:\OSDCloud\
├── Config\
│   └── Scripts\
│       ├── Start-OSDCloudZTI.ps1        <- Master launch script
│       └── Tenants.json                 <- Baked-in fallback config
├── Media\
│   └── (WinPE files - auto-generated)
└── OSDCloud.iso                         <- Output ISO
```

### PXE Server (iVentoy)

```text
iVentoy\
├── iso\
│   └── OSDCloud.iso                     <- Drop ISO here
└── (iVentoy application files)
```

### Hosted Config (Azure Blob, GitHub, or Web Server)

```text
https://yourstorageaccount.blob.core.windows.net/osdcloud/Tenants.json
```

---

## Tenants.json Reference

This file defines every customer. The script loads it in this priority order:

1. **URL** — best for PXE; update tenants without rebuilding ISO
2. **Baked into WinPE** — at `X:\OSDCloud\Config\Scripts\Tenants.json`
3. **USB drive** — fallback if a USB is attached

### Full Example

```json
{
  "Tenants": [
    {
      "TenantKey": "ClientA",
      "DisplayName": "Client A - Contoso",
      "TenantId": "00000000-0000-0000-0000-000000000000",
      "ClientId": "11111111-1111-1111-1111-111111111111",
      "ClientSecret": "YOUR_SECRET_HERE",
      "DefaultGroupTag": "CLIENTA-ZTI",
      "SerialPrefixMatch": ["CNA", "CNB"],
      "UseAutopilot": true
    },
    {
      "TenantKey": "ClientB",
      "DisplayName": "Client B - Fabrikam",
      "TenantId": "22222222-2222-2222-2222-222222222222",
      "ClientId": "33333333-3333-3333-3333-333333333333",
      "ClientSecret": "YOUR_SECRET_HERE",
      "DefaultGroupTag": "CLIENTB-ZTI",
      "SerialPrefixMatch": ["FAB", "FBK"],
      "UseAutopilot": true
    },
    {
      "TenantKey": "ClientC",
      "DisplayName": "Client C - Woodgrove (No Autopilot)",
      "UseAutopilot": false,
      "LocalAdmin": {
        "Username": "NCIAdmin",
        "EncryptedPassword": "",
        "PlainPassword": "CHANGE_ME_BEFORE_PRODUCTION"
      },
      "ComputerNamePrefix": "WDG",
      "SerialPrefixMatch": ["WDG"]
    }
  ]
}
```

### Autopilot Tenant Fields

| Field | Required | Description |
|-------|----------|-------------|
| `TenantKey` | Yes | Short unique key used with `-TenantKey` parameter |
| `DisplayName` | Yes | Friendly name shown in the interactive menu |
| `TenantId` | Yes | Entra tenant ID (GUID) |
| `ClientId` | Yes | App Registration client ID (GUID) |
| `ClientSecret` | Yes* | App Registration secret value. *Or use `EncryptedSecret` instead |
| `EncryptedSecret` | No | AES-encrypted secret (use with `-PromptForPassphrase`) |
| `DefaultGroupTag` | Yes | Autopilot group tag applied to uploaded devices |
| `SerialPrefixMatch` | No | Array of serial number prefixes for auto-matching |
| `UseAutopilot` | Yes | Must be `true` |

### Non-Autopilot Tenant Fields

| Field | Required | Description |
|-------|----------|-------------|
| `TenantKey` | Yes | Short unique key |
| `DisplayName` | Yes | Friendly name shown in the interactive menu |
| `UseAutopilot` | Yes | Must be `false` |
| `LocalAdmin.Username` | Yes | Local admin account name created on the device |
| `LocalAdmin.PlainPassword` | Yes* | Password in plain text. *Or use `EncryptedPassword` instead |
| `LocalAdmin.EncryptedPassword` | No | AES-encrypted password (use with `-PromptForPassphrase`) |
| `ComputerNamePrefix` | No | Auto-generates hostname as `PREFIX-LAST7SERIAL` |
| `SerialPrefixMatch` | No | Array of serial prefixes for auto-matching |

### Adding a New Customer

1. Open `Tenants.json`
2. Add a new object to the `Tenants` array (copy an existing entry as a template)
3. Fill in the fields for Autopilot or Non-Autopilot
4. Upload the updated file to your hosted URL
5. **No ISO rebuild needed** if using URL-based config

---

## Building the ISO

Run these commands **once** on your admin workstation as Administrator:

```powershell
# 1. Install modules
Install-Module OSD -Force -SkipPublisherCheck
Install-Module OSDCloud -Force -SkipPublisherCheck

# 2. Create WinPE template
New-OSDCloudTemplate -Language en-us -SetInputLocale en-us

# 3. Create workspace
New-OSDCloudWorkspace -WorkspacePath D:\OSDCloud

# 4. Copy scripts into workspace
$dest = "D:\OSDCloud\Config\Scripts"
if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force }
Copy-Item ".\Start-OSDCloudZTI.ps1" "$dest\" -Force
Copy-Item ".\Tenants.json"          "$dest\" -Force

# 5. Build WinPE with drivers and auto-launch
Edit-OSDCloudWinPE `
    -CloudDriver Dell,HP,Lenovo,IntelNet,WiFi `
    -StartURL 'https://yourhost.com/Start-OSDCloudZTI.ps1'

# 6. Generate ISO
New-OSDCloudISO
```

Output: `D:\OSDCloud\OSDCloud.iso`

### When to Rebuild the ISO

| Scenario | Rebuild Needed? |
|----------|-----------------|
| Add or remove a customer | No — update hosted `Tenants.json` |
| Rotate a client secret | No — update hosted `Tenants.json` |
| Change group tags | No — update hosted `Tenants.json` |
| Update WinPE drivers | **Yes** |
| New Windows ADK version | **Yes** |
| Change master script logic | **Yes** if baked in / No if using `-StartURL` |

---

## PXE Setup

### iVentoy (Recommended)

Best option for MSPs — lightweight, portable, Secure Boot and UEFI native.

1. Download from https://iventoy.com
2. Extract to a folder on your deployment server or laptop
3. Place `OSDCloud.iso` in the `iso/` folder
4. Launch iVentoy and open the web UI at `http://localhost:26000`
5. Set DHCP range (or configure existing DHCP — see below)
6. Select `OSDCloud.iso` and start the server

**If using an existing DHCP server**, set these options:

| DHCP Option | Value |
|-------------|-------|
| 66 (Boot Server) | IP address of your iVentoy server |
| 67 (Boot File) | `iventoy_loader_uefi` |

### WDS

If the customer already has Windows Deployment Services:

```powershell
# Mount ISO and import boot image
Mount-DiskImage -ImagePath "D:\OSDCloud\OSDCloud.iso"
$drive = (Get-DiskImage "D:\OSDCloud\OSDCloud.iso" | Get-Volume).DriveLetter
Import-WdsBootImage -Path "${drive}:\sources\boot.wim" -NewImageName "OSDCloud ZTI"
Dismount-DiskImage -ImagePath "D:\OSDCloud\OSDCloud.iso"
```

Clients will see **"OSDCloud ZTI"** in the WDS boot menu.

---

## USB Boot (Alternative)

If PXE is not available, you can still boot from USB:

```powershell
New-OSDCloudUSB
```

Then copy the scripts and config onto the USB data partition:

```powershell
$usb = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'OSDCloudUSB' }).DriveLetter
Copy-Item ".\Start-OSDCloudZTI.ps1" "${usb}:\OSDCloud\Scripts\" -Force
Copy-Item ".\Tenants.json"          "${usb}:\OSDCloud\Config\" -Force
```

---

## Deploying a Device

### Interactive (Default)

Just PXE boot or USB boot. The script will:

1. Run pre-flight checks
2. Show you a numbered tenant menu
3. Deploy Windows
4. Handle Autopilot or non-Autopilot automatically
5. Reboot

**No parameters needed.** Pick the customer number and walk away.

### Pre-Selected Tenant

Skip the menu entirely:

```powershell
Start-OSDCloudZTI.ps1 -TenantKey ClientA
```

### Force Non-Autopilot

Override an Autopilot tenant's config at runtime (useful for reimages):

```powershell
Start-OSDCloudZTI.ps1 -TenantKey ClientA -SkipAutopilot
```

### Custom Computer Name

Override the auto-generated hostname:

```powershell
Start-OSDCloudZTI.ps1 -TenantKey ClientC -ComputerName "WDG-LOBBY-01"
```

Auto-generated format is `PREFIX-LAST7SERIAL`, truncated to 15 characters for NetBIOS.

### Encrypted Secrets

If the tenant uses `EncryptedSecret` or `EncryptedPassword`:

```powershell
Start-OSDCloudZTI.ps1 -PromptForPassphrase
```

You will be prompted to enter the decryption passphrase at runtime.

### All Switches

| Switch | Description |
|--------|-------------|
| `-TenantKey <key>` | Select tenant by key (skip menu) |
| `-SkipAutopilot` | Force non-Autopilot path for any tenant |
| `-ComputerName <name>` | Override auto-generated hostname |
| `-GroupTagOverride <tag>` | Override default Autopilot group tag |
| `-PromptForPassphrase` | Decrypt encrypted secrets or passwords at runtime |
| `-ConfigUrl <url>` | Override default `Tenants.json` download URL |

---

## What Happens at Each Phase

| Phase | Name | What It Does | Can It Fail? |
|-------|------|--------------|--------------|
| 1 | Pre-flight | Checks TPM, Secure Boot, RAM (4 GB min), Disk (64 GB min) | Yes — halts if RAM or disk fail |
| 2 | Tenant Selection | Downloads config, selects tenant (URL, WinPE, or USB) | Yes — halts if no config found |
| 3 | Module Update | Installs/updates OSD and OSDCloud PowerShell modules | Warns but continues |
| 4 | OS Deployment | Runs `Start-OSDCloud` — wipes disk, installs Windows 11 | Yes — OSDCloud handles errors |
| 5a | Autopilot Upload | Collects hardware hash, uploads to Graph v1.0 | Yes — retries 5x then fails |
| 5b | Non-Autopilot Setup | Injects local admin and computer name via unattend and registry | Rarely |
| 6 | Finalize | Copies logs to OS drive, reboots in 10 seconds | No |

---

## After Reboot

### Autopilot Tenants

The device boots into OOBE, the Autopilot profile downloads, ESP runs, and Intune
policies plus apps install automatically.

**Nothing else to do.** The device will auto-enroll and configure itself.

### Non-Autopilot Tenants

The device boots, OOBE is skipped, and the local admin desktop appears.

Log in with the local admin credentials defined in `Tenants.json` and proceed
with manual setup as needed.

---

## Log Files

Logs are written during WinPE and copied to the OS drive before reboot.

| Location (WinPE) | Location (After Reboot) |
|-------------------|------------------------|
| `X:\OSDCloud\Logs\` | `C:\OSDCloud\Logs\` |

**Log file name:** `OSDCloudZTI.log`

Each line includes timestamp, level, and message:

```text
2026-05-12 14:32:01 [INFO] Phase 1: Pre-flight checks
2026-05-12 14:32:01 [INFO] TPM: Present and enabled
2026-05-12 14:32:02 [WARN] Secure Boot: Disabled
2026-05-12 14:32:05 [INFO] Tenant selected: Client A - Contoso (ClientA)
```

**If something goes wrong**, pull `C:\OSDCloud\Logs\OSDCloudZTI.log` from the
device and check the last `[ERROR]` or `[WARN]` entries.

---

## Updating Tenants Without Rebuilding the ISO

This is the main advantage of hosting `Tenants.json` at a URL.

1. Edit `Tenants.json` on your local machine
2. Upload to your hosted location:

```powershell
# Azure Blob example
az storage blob upload `
    --account-name youraccount `
    --container-name osdcloud `
    --name Tenants.json `
    --file .\Tenants.json `
    --overwrite
```

3. The next PXE boot will pull the updated config automatically

**No ISO rebuild. No USB updates. No downtime.**

---

## Encrypting Secrets

Plain-text secrets in `Tenants.json` work but are not ideal for production.
Use this helper to generate an encrypted blob:

```powershell
# Run on a secure admin machine
$Secret     = Read-Host "Enter secret value"          -AsSecureString
$Passphrase = Read-Host "Enter encryption passphrase" -AsSecureString

# Convert SecureString to plain for key derivation
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
$passPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$keyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($passPlain)
)

$encrypted = ConvertFrom-SecureString $Secret -Key $keyBytes
Write-Host "`nEncrypted value (paste into Tenants.json):`n" -ForegroundColor Green
Write-Host $encrypted
```

Then in `Tenants.json`:

- **Remove** `ClientSecret` (or leave it empty)
- **Add** `"EncryptedSecret": "<paste encrypted value here>"`

At runtime, use `-PromptForPassphrase` and enter the same passphrase.

The same process works for `LocalAdmin.EncryptedPassword` on non-Autopilot tenants.

---

## Troubleshooting

### Pre-flight fails on RAM or Disk

The device genuinely does not meet minimum requirements. Check hardware.

### Tenants.json not found

- **PXE:** Verify the `$ConfigUrl` in the script is correct and reachable from
  the deployment network. Test with `Invoke-RestMethod -Uri <url>` from a machine
  on the same network.
- **USB:** Ensure `Tenants.json` is at `USB:\OSDCloud\Config\Tenants.json`.
- **Baked-in:** Rebuild the ISO with the file in `D:\OSDCloud\Config\Scripts\`.

### TenantKey not found

The `-TenantKey` value does not match any `TenantKey` in `Tenants.json`.
Check spelling and case — it is case-sensitive.

### Graph token request fails (Autopilot)

- Verify `TenantId` and `ClientId` are correct GUIDs
- Verify the client secret has not expired
- Verify admin consent was granted for `DeviceManagementServiceConfig.ReadWrite.All`
- Verify the device has internet access in WinPE (check Wi-Fi or Ethernet)

### Hash upload fails with HTTP 400

- The hardware hash may be malformed. Check `OSDCloudZTI.log` for hash length.
  A valid hash is typically 4,000+ characters.
- Ensure `MDM_DevDetail_Ext01` is accessible. This requires WinPE with MDM WMI
  support or full OS OOBE.

### Hash upload fails with HTTP 403

- App Registration permissions are wrong or admin consent was not granted.
- The secret may belong to a different app registration.

### Hash upload fails with HTTP 409

- The device is already registered in Autopilot for that tenant. This is safe
  to ignore — the device will still pick up its Autopilot profile.

### Computer name not applying (Non-Autopilot)

- Verify the offline OS drive was detected (check log for "Offline OS drive:").
- Ensure the SYSTEM registry hive at `<drive>:\Windows\System32\config\SYSTEM`
  is not corrupted.

### OSDCloud module will not install

- WinPE must have internet access. Check network connectivity.
- The script will warn but continue. OSDCloud may still work if it was previously
  cached in the WinPE image.

### Device boots to OOBE but Autopilot does not activate

- The hash upload succeeded but the Autopilot profile has not been assigned yet.
- Check **Intune** > **Devices** > **Enrollment** > **Windows Autopilot devices**.
- Ensure a dynamic group with the correct group tag is targeting an Autopilot
  deployment profile.
- It can take up to 15 minutes for the profile to assign after hash upload.

---

## FAQ

**Q: Can I use this for Windows 10?**
A: Yes. Change `-OSName 'Windows 11'` to `-OSName 'Windows 10'` in the script.

**Q: Can I change the OS edition?**
A: Yes. Change `-OSEdition Enterprise` to `Pro` or another supported edition.

**Q: What if the device has no internet in WinPE?**
A: OSDCloud requires internet to download the OS and drivers. Use
`-CloudDriver WiFi` in your WinPE build to enable Wi-Fi, or ensure Ethernet
is connected.

**Q: Can I use this with BIOS or Legacy boot?**
A: No. OSDCloud targets UEFI only. All modern devices (2016+) support UEFI.

**Q: How do I update the master script without rebuilding the ISO?**
A: If you built WinPE with `-StartURL`, the script is downloaded fresh at every
boot. Just update the hosted script file.

**Q: Can multiple techs PXE boot at the same time?**
A: Yes. Each device runs its own instance of WinPE in RAM. iVentoy handles
concurrent boots natively.

**Q: What if a device serial does not match any prefix?**
A: The interactive menu will appear. The tech picks the customer manually.

**Q: Is the Autopilot hash upload idempotent?**
A: Uploading the same hash twice returns HTTP 409 (conflict). The device is
already registered — no harm done.

---

## Security Notes

- **Rotate client secrets** every 6 to 12 months
- **Use `EncryptedSecret`** in production instead of plain-text `ClientSecret`
- **Use Azure Blob with a SAS token** (read-only, time-limited) for hosting `Tenants.json`
- **Restrict App Registrations** to single-tenant (not multi-tenant app type)
- **Use LAPS** to rotate the non-Autopilot local admin password post-deployment
- **Never commit `Tenants.json` with plain secrets** to a public Git repo
- **The unattend.xml** (non-Autopilot) is written to the offline OS drive only,
  not persisted on the USB or PXE server

---

## Contact

Questions, issues, or tenant onboarding requests — reach out to Tate
