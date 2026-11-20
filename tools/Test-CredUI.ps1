<#
.SYNOPSIS
    Opent het Windows CredUI-venster (CredUIPromptForWindowsCredentialsW) om te zien
    hoe de credential provider zich gedraagt in het CPUS_CREDUI-scenario.

.DESCRIPTION
    Er wordt NIET ingelogd: het script toont alleen wat de gekozen credential provider
    teruggeeft (gebruikersnaam, domein, lengte van het wachtwoord - nooit het wachtwoord zelf).

    Draai het in verschillende contexten om het verschil te zien:
      - als gewone gebruiker              : powershell -ExecutionPolicy Bypass -File Test-CredUI.ps1
      - als elevated beheerder            : idem, vanuit een "Als administrator uitvoeren"-prompt
      - als SYSTEM (zoals consent.exe)    : psexec -s -i powershell -ExecutionPolicy Bypass -File Test-CredUI.ps1

    Gebruik 64-bit PowerShell: een 32-bit proces laadt alleen 32-bit credential providers.

.EXAMPLE
    .\Test-CredUI.ps1
.EXAMPLE
    .\Test-CredUI.ps1 -PrefillUser 'DOMEIN\jan' -AuthPackageOnly
.EXAMPLE
    .\Test-CredUI.ps1 -EnumerateAdmins     # zoals een UAC-prompt voor een standaardgebruiker
#>
param(
    [string]$Caption = "CredUI-test",
    [string]$Message = "Test van de credential provider in CredUI (CPUS_CREDUI)",
    [string]$PrefillUser,
    [switch]$AuthPackageOnly,
    [switch]$InCredOnly,
    [switch]$EnumerateAdmins,
    [switch]$EnumerateCurrentUser,
    [switch]$Checkbox,
    [switch]$SecurePrompt
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CredUITest
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDUI_INFO
    {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    public static extern int CredUIPromptForWindowsCredentialsW(
        ref CREDUI_INFO pUiInfo, int dwAuthError, ref uint pulAuthPackage,
        IntPtr pvInAuthBuffer, uint ulInAuthBufferSize,
        out IntPtr ppvOutAuthBuffer, out uint pulOutAuthBufferSize,
        ref bool pfSave, uint dwFlags);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredPackAuthenticationBufferW(
        uint dwFlags, string pszUserName, string pszPassword,
        IntPtr pPackedCredentials, ref uint pcbPackedCredentials);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredUnPackAuthenticationBufferW(
        uint dwFlags, IntPtr pAuthBuffer, uint cbAuthBuffer,
        StringBuilder pszUserName, ref uint pcchMaxUserName,
        StringBuilder pszDomainName, ref uint pcchMaxDomainName,
        StringBuilder pszPassword, ref uint pcchMaxPassword);
}
'@

# --- Context tonen: in welk account draait dit (en dus de credential provider)? ---
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($id)
$isSystem = $id.User.IsWellKnown([System.Security.Principal.WellKnownSidType]::LocalSystemSid)
$isElevatedAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Account          : $($id.Name)"
Write-Host "SYSTEM           : $isSystem"
Write-Host "Elevated admin   : $isElevatedAdmin"
Write-Host "64-bit proces    : $([Environment]::Is64BitProcess)"
Write-Host ""

# --- Flags (wincred.h) ---
$CREDUIWIN_CHECKBOX               = 0x00000002
$CREDUIWIN_AUTHPACKAGE_ONLY       = 0x00000010
$CREDUIWIN_IN_CRED_ONLY           = 0x00000020
$CREDUIWIN_ENUMERATE_ADMINS       = 0x00000100
$CREDUIWIN_ENUMERATE_CURRENT_USER = 0x00000200
$CREDUIWIN_SECURE_PROMPT          = 0x00001000

[uint32]$flags = 0
if ($Checkbox)             { $flags = $flags -bor $CREDUIWIN_CHECKBOX }
if ($AuthPackageOnly)      { $flags = $flags -bor $CREDUIWIN_AUTHPACKAGE_ONLY }
if ($InCredOnly)           { $flags = $flags -bor $CREDUIWIN_IN_CRED_ONLY }
if ($EnumerateAdmins)      { $flags = $flags -bor $CREDUIWIN_ENUMERATE_ADMINS }
if ($EnumerateCurrentUser) { $flags = $flags -bor $CREDUIWIN_ENUMERATE_CURRENT_USER }
if ($SecurePrompt)         { $flags = $flags -bor $CREDUIWIN_SECURE_PROMPT }
Write-Host ("dwFlags          : 0x{0:X8}" -f $flags)

# --- Optioneel: invoerbuffer met voorgevulde gebruikersnaam (komt binnen via SetSerialization) ---
$inBuf = [IntPtr]::Zero
[uint32]$inSize = 0
if ($PrefillUser) {
    [void][CredUITest]::CredPackAuthenticationBufferW(0, $PrefillUser, "", [IntPtr]::Zero, [ref]$inSize)
    $inBuf = [System.Runtime.InteropServices.Marshal]::AllocCoTaskMem([int]$inSize)
    if (-not [CredUITest]::CredPackAuthenticationBufferW(0, $PrefillUser, "", $inBuf, [ref]$inSize)) {
        throw "CredPackAuthenticationBufferW mislukt: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Write-Host "Voorgevuld       : $PrefillUser"
}

$info = New-Object CredUITest+CREDUI_INFO
$info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
$info.pszCaptionText = $Caption
$info.pszMessageText = $Message

[uint32]$authPackage = 0
$outBuf = [IntPtr]::Zero
[uint32]$outSize = 0
$save = $false

$rc = [CredUITest]::CredUIPromptForWindowsCredentialsW([ref]$info, 0, [ref]$authPackage,
        $inBuf, $inSize, [ref]$outBuf, [ref]$outSize, [ref]$save, $flags)

if ($inBuf -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($inBuf) }

Write-Host ""
switch ($rc) {
    0       { Write-Host "Resultaat        : OK (auth package $authPackage, buffer $outSize bytes)" }
    1223    { Write-Host "Resultaat        : geannuleerd door gebruiker"; return }
    default { Write-Host "Resultaat        : fout $rc"; return }
}

# --- Uitpakken: alleen naam/domein en de LENGTE van het wachtwoord tonen ---
[uint32]$uLen = 513; [uint32]$dLen = 337; [uint32]$pLen = 1024
$u = New-Object System.Text.StringBuilder ([int]$uLen)
$d = New-Object System.Text.StringBuilder ([int]$dLen)
$p = New-Object System.Text.StringBuilder ([int]$pLen)
if ([CredUITest]::CredUnPackAuthenticationBufferW(0, $outBuf, $outSize, $u, [ref]$uLen, $d, [ref]$dLen, $p, [ref]$pLen)) {
    Write-Host "Gebruiker        : $($u.ToString())"
    Write-Host "Domein           : $($d.ToString())"
    Write-Host "Wachtwoordlengte : $($p.Length)"
} else {
    Write-Host "CredUnPackAuthenticationBufferW mislukt: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

# Opruimen: wachtwoord en buffer overschrijven, buffer vrijgeven
[void]$p.Clear(); [void]$p.Append([char]0, [int]$p.Capacity); [void]$p.Clear()
if ($outBuf -ne [IntPtr]::Zero) {
    [System.Runtime.InteropServices.Marshal]::Copy((New-Object byte[] ([int]$outSize)), 0, $outBuf, [int]$outSize)
    [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($outBuf)
}
