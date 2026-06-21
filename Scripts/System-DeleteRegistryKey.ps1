#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$ProviderPath,
    [Parameter(Mandatory)][string]$RegPath,
    [Parameter(Mandatory)][string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LogLine {
    param([string]$Message)
    Add-Content -Path $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) -Encoding UTF8
}

if (-not ([System.Management.Automation.PSTypeName]'RegFixHelper').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;

public class RegFixHelper {
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public int PrivilegeCount;
        public long Luid;
        public int Attributes;
    }

    private const int SE_PRIVILEGE_ENABLED = 0x00000002;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint TOKEN_QUERY = 0x0008;

    public static void EnablePrivilege(string privilege) {
        IntPtr tokenHandle;
        if (!OpenProcessToken(Process.GetCurrentProcess().Handle, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tokenHandle))
            throw new Exception("OpenProcessToken failed");
        try {
            long luid;
            if (!LookupPrivilegeValue(null, privilege, out luid))
                throw new Exception("LookupPrivilegeValue failed for " + privilege);
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;
            AdjustTokenPrivileges(tokenHandle, false, ref tp, (uint)Marshal.SizeOf(tp), IntPtr.Zero, IntPtr.Zero);
        } finally {
            CloseHandle(tokenHandle);
        }
    }

    public static void SetOwnershipAndPermission(string subKeyPath) {
        var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        NTAccount systemAccount = new NTAccount("NT AUTHORITY\\SYSTEM");

        // Step 1: Take ownership
        var key = baseKey.OpenSubKey(subKeyPath, RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryRights.TakeOwnership);
        if (key == null) throw new Exception("Cannot open for TakeOwnership: " + subKeyPath);
        try {
            var acl = key.GetAccessControl(AccessControlSections.Owner);
            acl.SetOwner(systemAccount);
            key.SetAccessControl(acl);
        } finally { key.Close(); }

        // Step 2: Open for ChangePermissions, remove DENY ACEs, add FullControl
        key = baseKey.OpenSubKey(subKeyPath, RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryRights.ChangePermissions);
        if (key == null) throw new Exception("Cannot open for ChangePermissions: " + subKeyPath);
        try {
            var acl = key.GetAccessControl();

            // Remove all DENY ACEs that block access (C# 5.0 compatible - no pattern matching)
            var denyRules = acl.GetAccessRules(true, false, typeof(NTAccount));
            foreach (AuthorizationRule rule in denyRules) {
                var regRule = rule as RegistryAccessRule;
                if (regRule != null && regRule.AccessControlType == AccessControlType.Deny) {
                    acl.RemoveAccessRuleSpecific(regRule);
                }
            }

            // Add FullControl for SYSTEM
            var allowRule = new RegistryAccessRule(
                systemAccount,
                RegistryRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow);
            acl.AddAccessRule(allowRule);
            key.SetAccessControl(acl);
        } finally { key.Close(); }
    }

    public static void DeleteSubKeyTree(string parentPath, string leafName) {
        var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        var parentKey = baseKey.OpenSubKey(parentPath, true);
        if (parentKey == null) throw new Exception("Cannot open parent: " + parentPath);
        try {
            parentKey.DeleteSubKeyTree(leafName, false);
        } finally {
            parentKey.Close();
        }
    }
}
'@
}

try {
    Write-LogLine ('TrustedInstaller delete start: {0}' -f $ProviderPath)
    if ($ProviderPath -notmatch '^HKLM:\\(.+)$') {
        throw "Invalid ProviderPath: $ProviderPath"
    }
    $subKey = $Matches[1]
    $leaf = Split-Path -Path $subKey -Leaf
    $parentPath = Split-Path -Path $subKey -Parent

    # Enable privileges
    [RegFixHelper]::EnablePrivilege('SeTakeOwnershipPrivilege')
    [RegFixHelper]::EnablePrivilege('SeRestorePrivilege')
    [RegFixHelper]::EnablePrivilege('SeBackupPrivilege')
    Write-LogLine 'Privileges enabled'

    # Take ownership of the entire chain from Overrides down
    $marker = 'FeatureManagement\Overrides'
    $idx = $subKey.IndexOf($marker)
    if ($idx -ge 0) {
        $base = $subKey.Substring(0, $idx + $marker.Length)
        $relative = $subKey.Substring($idx + $marker.Length).TrimStart('\')
        $chain = @($base)
        if ($relative) {
            $current = $base
            foreach ($part in ($relative -split '\\')) {
                if ([string]::IsNullOrWhiteSpace($part)) { continue }
                $current = "$current\$part"
                $chain += $current
            }
        }
        foreach ($chainPath in $chain) {
            try {
                [RegFixHelper]::SetOwnershipAndPermission($chainPath)
                Write-LogLine ("Ownership set: $chainPath")
            } catch {
                Write-LogLine ("Ownership warning for ${chainPath}: $($_.Exception.Message)")
            }
        }
    }

    # Now delete
    [RegFixHelper]::DeleteSubKeyTree($parentPath, $leaf)
    Write-LogLine 'DeleteSubKeyTree succeeded'
    exit 0
} catch {
    Write-LogLine ('DeleteSubKeyTree failed: {0}' -f $_.Exception.Message)
    try {
        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        $output = & $regExe delete $RegPath /f 2>&1 | Out-String
        Write-LogLine ('reg.exe output: {0}' -f $output.Trim())
        if ($LASTEXITCODE -ne 0) {
            exit [int][Math]::Max($LASTEXITCODE, 1)
        }
        Write-LogLine 'reg.exe succeeded'
        exit 0
    } catch {
        Write-LogLine ('reg.exe also failed: {0}' -f $_.Exception.Message)
        exit 1
    }
}
