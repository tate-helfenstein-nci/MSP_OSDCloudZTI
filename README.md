PXE / USB Boot
→ WinPE loads
→ Pre-flight checks (TPM, Secure Boot, RAM, Disk)
→ Tenant selection (menu, serial match, or parameter)
→ Windows 11 deployed via OSDCloud (ZTI)
→ Post-deploy:
├─ Autopilot tenant → Hash uploaded to Microsoft Graph
└─ Non-Autopilot tenant → Local admin + computer name injected
→ Logs copied to OS drive
→ Reboot
→ OOBE / Autopilot / Manual login

**You do not need to touch the device after PXE boot** unless tenant selection
requires the interactive menu.

---

## What You Need

| Requirement                  | Details                                                  |
|------------------------------|----------------------------------------------------------|
| Admin workstation            | Windows 10/11 with internet access                       |
| Windows ADK                  | Matching your target OS generation                       |
| Windows PE Add-on for ADK    | Required for WinPE image creation                        |
| PowerShell 5.1+              | Ships with Windows 10/11                                 |
| OSD + OSDCloud modules       | `Install-Module OSD, OSDCloud -Force`                    |
| PXE server (for PXE boot)    | iVentoy (recommended) or WDS                             |
| App Registration per tenant  | Autopilot tenants only — see permissions below            |

### App Registration Permissions (Autopilot Tenants Only)

Each Autopilot customer tenant needs an Entra ID App Registration with:


Microsoft Graph → Application permissions:
DeviceManagementServiceConfig.ReadWrite.All

**Admin consent required.** Create a client secret and store the value in `Tenants.json`.

---

## Folder Structure

### Build Machine


D:\OSDCloud\                          ← Workspace
├── Config
│   └── Scripts
│       ├── Start-OSDCloudZTI.ps1      ← Master launch script
│       └── Tenants.json               ← Baked-in fallback config
└── OSDCloud.iso                       ← Output ISO (auto-generated)

### PXE Server


iVentoy
├── iso
│   └── OSDCloud.iso                   ← Drop ISO here
└── (iVentoy application files)

### Hosted Config (Azure Blob / GitHub / Web Server)


https://yourstorageaccount.blob.core.windows.net/osdcloud/Tenants.json

---

## Tenants.json Reference

This file defines every customer. The script loads it in this priority order:

1. **URL** (best for PXE — update tenants without rebuilding ISO)
2. **Baked into WinPE** at `X:\OSDCloud\Config\Scripts\Tenants.json`
3. **USB drive** (fallback if a USB is attached)

### Autopilot Tenant

```json
{
  "TenantKey": "ClientA",
  "DisplayName": "Client A - Contoso",
  "TenantId": "00000000-0000-0000-0000-000000000000",
  "ClientId": "11111111-1111-1111-1111-111111111111",
  "ClientSecret": "YOUR_SECRET_HERE",
  "DefaultGroupTag": "CLIENTA-ZTI",
  "SerialPrefixMatch": [ "CNA", "CNB" ],
  "UseAutopilot": true
}
























































FieldRequiredDescriptionTenantKeyYesShort unique key used with -TenantKey parameterDisplayNameYesFriendly name shown in the menuTenantIdYesEntra tenant ID (GUID)ClientIdYesApp Registration client ID (GUID)ClientSecretYes*App Registration secret value (*or use EncryptedSecret)EncryptedSecretNoAES-encrypted secret (use with -PromptForPassphrase)DefaultGroupTagYesAutopilot group tag applied to uploaded devicesSerialPrefixMatchNoArray of serial number prefixes for auto-matchingUseAutopilotYesMust be true
Non-Autopilot Tenant
JSON{  "TenantKey": "ClientC",  "DisplayName": "Client C - Woodgrove (No Autopilot)",  "UseAutopilot": false,  "LocalAdmin": {    "Username": "NCIAdmin",    "EncryptedPassword": "",    "PlainPassword": "CHANGE_ME_BEFORE_PRODUCTION"  },  "ComputerNamePrefix": "WDG",  "SerialPrefixMatch": [ "WDG" ]}Show more lines


















































FieldRequiredDescriptionTenantKeyYesShort unique keyDisplayNameYesFriendly name shown in the menuUseAutopilotYesMust be falseLocalAdmin.UsernameYesLocal admin account name created on the deviceLocalAdmin.PlainPasswordYes*Password in plain text (*or use EncryptedPassword)LocalAdmin.EncryptedPasswordNoAES-encrypted password (use with -PromptForPassphrase)ComputerNamePrefixNoAuto-generates hostname: PREFIX-LAST7SERIALSerialPrefixMatchNoArray of serial prefixes for auto-matching

No App Registration, TenantId, or ClientId needed for non-Autopilot tenants.

Adding a New Customer

Open Tenants.json
Add a new object to the Tenants array (copy an existing one as a template)
Fill in the fields for Autopilot or Non-Autopilot
Upload the updated file to your hosted URL
No ISO rebuild needed if using URL-based config


Building the ISO
Run these commands once on your admin workstation (as Administrator):
PowerShell# 1. Install modulesInstall-Module OSD -Force -SkipPublisherCheckInstall-Module OSDCloud -Force -SkipPublisherCheck# 2. Create WinPE templateNew-OSDCloudTemplate -Language en-us -SetInputLocale en-us# 3. Create workspaceNew-OSDCloudWorkspace -WorkspacePath D:\OSDCloud# 4. Copy scripts into workspace$dest = "D:\OSDCloud\Config\Scripts"if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force }Copy-Item ".\Start-OSDCloudZTI.ps1" "$dest\" -ForceCopy-Item ".\Tenants.json"          "$dest\" -Force# 5. Build WinPE with drivers and auto-launchEdit-OSDCloudWinPE `    -CloudDriver Dell,HP,Lenovo,IntelNet,WiFi `    -StartURL 'https://yourhost.com/Start-OSDCloudZTI.ps1'# 6. Generate ISONew-OSDCloudISOShow less
Output: D:\OSDCloud\OSDCloud.iso
When to Rebuild the ISO

































ScenarioRebuild needed?Add/remove a customer❌ No (update hosted Tenants.json)Rotate a client secret❌ No (update hosted Tenants.json)Change group tags❌ No (update hosted Tenants.json)Update WinPE drivers✅ YesNew Windows ADK version✅ YesChange the master script logic✅ Yes (if baked in) / ❌ No (if using -StartURL)

PXE Setup
iVentoy (Recommended)
Best option for MSPs — lightweight, portable, Secure Boot + UEFI native.

Download from https://iventoy.com
Extract to a folder on your deployment server or laptop
Place OSDCloud.iso in the iso/ folder
Launch iVentoy → open web UI at http://localhost:26000
Set DHCP range (or configure existing DHCP — see below)
Select OSDCloud.iso → Start server

If using existing DHCP server, set these options:

















DHCP OptionValue66 (Boot Server)<iVentoy server IP>67 (Boot File)iventoy_loader_uefi
WDS
If the customer has Windows Deployment Services:
PowerShell# Mount ISO and import boot imageMount-DiskImage -ImagePath "D:\OSDCloud\OSDCloud.iso"$drive = (Get-DiskImage "D:\OSDCloud\OSDCloud.iso" | Get-Volume).DriveLetterImport-WdsBootImage -Path "${drive}:\sources\boot.wim" -NewImageName "OSDCloud ZTI"Dismount-DiskImage -ImagePath "D:\OSDCloud\OSDCloud.iso"Show more lines
Clients will see "OSDCloud ZTI" in the WDS boot menu.

USB Boot (Alternative)
If PXE isn't available, you can still boot from USB:
PowerShellNew-OSDCloudUSBShow more lines
Then copy the scripts and config onto the USB data partition:
PowerShell$usb = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'OSDCloudUSB' }).DriveLetterCopy-Item ".\Start-OSDCloudZTI.ps1" "${usb}:\OSDCloud\Scripts\" -ForceCopy-Item ".\Tenants.json"          "${usb}:\OSDCloud\Config\" -ForceShow more lines

Deploying a Device
Interactive (Default)
Just PXE boot or USB boot. The script will:

Run pre-flight checks
Show you a numbered tenant menu
Deploy Windows
Handle Autopilot or non-Autopilot automatically
Reboot

No parameters needed. Pick the customer number and walk away.
Pre-Selected Tenant
Skip the menu entirely:
PowerShellStart-OSDCloudZTI.ps1 -TenantKey ClientAShow more lines
Force Non-Autopilot
Override an Autopilot tenant's config at runtime (useful for reimages):
PowerShellStart-OSDCloudZTI.ps1 -TenantKey ClientA -SkipAutopilotShow more lines
Custom Computer Name
Override the auto-generated hostname:
PowerShellStart-OSDCloudZTI.ps1 -TenantKey ClientC -ComputerName "WDG-LOBBY-01"Show more lines

Auto-generated format: PREFIX-LAST7SERIAL (truncated to 15 chars for NetBIOS).

Encrypted Secrets
If the tenant uses EncryptedSecret or EncryptedPassword:
PowerShellStart-OSDCloudZTI.ps1 -PromptForPassphraseShow more lines
You'll be prompted to enter the decryption passphrase at runtime.
All Switches

































SwitchDescription-TenantKey <key>Select tenant by key (skip menu)-SkipAutopilotForce non-Autopilot path for any tenant-ComputerName <name>Override auto-generated hostname-GroupTagOverride <tag>Override default Autopilot group tag-PromptForPassphraseDecrypt encrypted secrets/passwords at runtime-ConfigUrl <url>Override default Tenants.json download URL

What Happens at Each Phase





















































PhaseNameWhat It DoesCan It Fail?1Pre-flightChecks TPM, Secure Boot, RAM (≥4 GB), Disk (≥64 GB)Yes — halts if RAM or disk fail2Tenant SelectionDownloads config, selects tenant (URL → WinPE → USB)Yes — halts if no config found3Module UpdateInstalls/updates OSD + OSDCloud PowerShell modulesWarns but continues4OS DeploymentRuns Start-OSDCloud — wipes disk, installs Windows 11Yes — OSDCloud handles errors5aAutopilot UploadCollects hardware hash, uploads to Graph v1.0Yes — retries 5x then fails5bNon-Autopilot SetupInjects local admin + computer name via unattend/registryRarely6FinalizeCopies logs to OS drive, reboots in 10 secondsNo

After Reboot
Autopilot Tenants
Device boots → OOBE → Autopilot profile downloads → ESP runs → Intune policies + apps install

Nothing else to do. The device will auto-enroll and configure itself.
Non-Autopilot Tenants
Device boots → OOBE is skipped → Local admin desktop appears

Log in with the local admin credentials defined in Tenants.json and proceed with
manual setup or domain join as needed.

Log Files
Logs are written during WinPE and copied to the OS drive before reboot.













Location (WinPE)Location (After Reboot)X:\OSDCloud\Logs\C:\OSDCloud\Logs\
Log file: OSDCloudZTI.log
Each line includes timestamp, level, and message:
2026-05-12 14:32:01 [INFO] Phase 1: Pre-flight checks
2026-05-12 14:32:01 [INFO] TPM: Present and enabled
2026-05-12 14:32:02 [WARN] Secure Boot: Disabled
2026-05-12 14:32:05 [INFO] Tenant selected: Client A - Contoso (ClientA)

If something goes wrong, pull C:\OSDCloud\Logs\OSDCloudZTI.log from the device
and check the last [ERROR] or [WARN] entries.

Updating Tenants Without Rebuilding the ISO
This is the main advantage of hosting Tenants.json at a URL.

Edit Tenants.json on your local machine
Upload to your hosted location:

PowerShell# Azure Blob exampleaz storage blob upload `    --account-name youraccount `    --container-name osdcloud `    --name Tenants.json `    --file .\Tenants.json `    --overwriteShow more lines

Next PXE boot will pull the updated config automatically

No ISO rebuild. No USB updates. No downtime.

Encrypting Secrets
Plain-text secrets in Tenants.json work but aren't ideal for production.
Use this helper to generate an encrypted blob:
PowerShell# Run on a secure admin machine$Secret     = Read-Host "Enter secret value"     -AsSecureString$Passphrase = Read-Host "Enter encryption passphrase" -AsSecureString# Convert SecureString to plain for key derivation$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)$passPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)$keyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(    [System.Text.Encoding]::UTF8.GetBytes($passPlain))$encrypted = ConvertFrom-SecureString $Secret -Key $keyBytesWrite-Host "`nEncrypted value (paste into Tenants.json):`n" -ForegroundColor GreenWrite-Host $encryptedShow more lines
Then in Tenants.json:

Remove ClientSecret (or leave it empty)
Add "EncryptedSecret": "<paste encrypted value here>"

At runtime, use -PromptForPassphrase and enter the same passphrase.
The same process works for LocalAdmin.EncryptedPassword on non-Autopilot tenants.

Troubleshooting
Pre-flight fails on RAM or Disk
The device genuinely doesn't meet minimum requirements. Check hardware.
"Tenants.json not found"

PXE: Verify the $ConfigUrl in the script is correct and reachable from the
deployment network. Test with Invoke-RestMethod -Uri <url> from a machine on
the same network.
USB: Ensure Tenants.json is at USB:\OSDCloud\Config\Tenants.json.
Baked-in: Rebuild the ISO with the file in D:\OSDCloud\Config\Scripts\.

"TenantKey 'X' not found"
The -TenantKey value doesn't match any TenantKey in Tenants.json. Check
spelling and case — it's case-sensitive.
Graph token request fails (Autopilot)

Verify TenantId and ClientId are correct GUIDs
Verify the client secret hasn't expired
Verify admin consent was granted for DeviceManagementServiceConfig.ReadWrite.All
Verify the device has internet access in WinPE (check Wi-Fi / Ethernet)

Hash upload fails with HTTP 400

The hardware hash may be malformed. Check OSDCloudZTI.log for hash length.
A valid hash is typically 4,000+ characters.
Ensure MDM_DevDetail_Ext01 is accessible — this requires WinPE with MDM WMI
support or full OS OOBE.

Hash upload fails with HTTP 403

App Registration permissions are wrong or admin consent wasn't granted.
The secret may belong to a different app registration.

Hash upload fails with HTTP 409

The device is already registered in Autopilot for that tenant. This is safe to
ignore — the device will still pick up its Autopilot profile.

Computer name not applying (Non-Autopilot)

Verify the offline OS drive was detected (check log for "Offline OS drive:").
Ensure the SYSTEM registry hive at <drive>:\Windows\System32\config\SYSTEM
is not corrupted.

OSDCloud module won't install

WinPE must have internet access. Check network connectivity.
The script will warn but continue — OSDCloud may still work if it was previously
cached in the WinPE image.

Device boots to OOBE but Autopilot doesn't activate

The hash upload succeeded but the Autopilot profile hasn't been assigned yet.
Check Intune → Devices → Enrollment → Windows Autopilot devices.
Ensure a dynamic group with the correct group tag is targeting an Autopilot
deployment profile.
It can take up to 15 minutes for the profile to assign after hash upload.


FAQ
Q: Can I use this for Windows 10?
A: Yes. Change -OSName 'Windows 11' to -OSName 'Windows 10' in the script.
Q: Can I change the OS edition?
A: Yes. Change -OSEdition Enterprise to Pro or another supported edition.
Q: What if the device has no internet in WinPE?
A: OSDCloud requires internet to download the OS and drivers. Use
-CloudDriver WiFi in your WinPE build to enable Wi-Fi, or ensure Ethernet is
connected.
Q: Can I use this with BIOS/Legacy boot?
A: No. OSDCloud targets UEFI only. All modern devices (2016+) support UEFI.
Q: How do I update the master script without rebuilding the ISO?
A: If you built WinPE with -StartURL, the script is downloaded fresh at every
boot. Just update the hosted script file.
Q: Can multiple techs PXE boot at the same time?
A: Yes. Each device runs its own instance of WinPE in RAM. iVentoy handles
concurrent boots natively.
Q: What if a device's serial doesn't match any prefix?
A: The interactive menu will appear. The tech picks the customer manually.
Q: Is the Autopilot hash upload idempotent?
A: Uploading the same hash twice returns HTTP 409 (conflict). The device is
already registered — no harm done.

Security Notes

🔒 Rotate client secrets every 6–12 months
🔒 Use EncryptedSecret in production instead of plain-text ClientSecret
🔒 Use Azure Blob + SAS token with read-only, time-limited access for
hosting Tenants.json
🔒 Restrict App Registrations to single-tenant (not multi-tenant app type)
🔒 Use LAPS to rotate the non-Autopilot local admin password post-deployment
🔒 Never commit Tenants.json with plain secrets to a public Git repo
🔒 The unattend.xml (non-Autopilot) is written to the offline OS drive only,
not persisted on the USB or PXE server


Contact
Questions, issues, or tenant onboarding requests → reach out to the
Infrastructure Engineering team.
