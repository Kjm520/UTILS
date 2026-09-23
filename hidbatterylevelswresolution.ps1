# Find any HID device that reports battery level - no device path or name needed.
# Scans every present HID interface for battery usages in its report descriptor:
#   Usage Page 0x85 (Battery System): 0x64 RelativeStateOfCharge, 0x65 AbsoluteStateOfCharge, 0x66 RemainingCapacity
#   Usage Page 0x06 (Generic Device Controls): 0x20 Battery Strength
if (-not ('HidScan' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HidScan {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string f, uint a, uint s, IntPtr se, uint d, uint fl, IntPtr t);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr ppd);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr ppd);
  [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr ppd, byte[] caps);
  [DllImport("hid.dll")] public static extern int HidP_GetValueCaps(int type, byte[] caps, ref ushort len, IntPtr ppd);
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] b, int l);
  [DllImport("hid.dll")] public static extern bool HidD_GetInputReport(IntPtr h, byte[] b, int l);
  [DllImport("hid.dll")] public static extern int HidP_GetUsageValue(int type, ushort page, ushort link, ushort usage, out uint v, IntPtr ppd, byte[] r, uint rl);
  [DllImport("hid.dll", CharSet=CharSet.Unicode)] public static extern bool HidD_GetProductString(IntPtr h, StringBuilder s, int l);
}
'@ }

# Walk up the device parent chain to the physical product's name. USB: the last
# non-empty bus-reported description below the root hub is the product string.
# Bluetooth: the name lives on the sibling BTHENUM\DEV_<mac> node, found via the
# MAC embedded in an ancestor's instance ID.
function Resolve-HidDeviceName([string]$id, [string]$fallback) {
  $best = $null
  $cur = $id
  for ($i = 0; $i -lt 5 -and $cur; $i++) {
    if ($cur -match '(?i)&([0-9A-F]{12})_C00000000') {
      $mac = $Matches[1]
      $dev = Get-PnpDevice -PresentOnly | Where-Object InstanceId -like "BTHENUM\DEV_$mac*" | Select-Object -First 1
      if ($dev.FriendlyName) { return $dev.FriendlyName }
    }
    if ($cur -match '^(USB\\ROOT|PCI\\)') { break }
    $bus = (Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue).Data
    if ($bus) { $best = $bus }
    $cur = (Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
  }
  if ($best) { $best } else { $fallback }
}

$batteryUsages = @(
  @{ Page = 0x85; Usages = 0x64, 0x65, 0x66 },   # Battery System
  @{ Page = 0x06; Usages = ,0x20 }               # Generic Device Controls / Battery Strength
)

foreach ($id in (Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'HID\*').InstanceId) {
  $path = '\\?\' + $id.Replace('\','#') + '#{4d1e55b2-f16f-11cf-88cb-001111000030}'
  $h = [HidScan]::CreateFileW($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq [IntPtr](-1)) { continue }
  $ppd = [IntPtr]::Zero
  if (-not [HidScan]::HidD_GetPreparsedData($h, [ref]$ppd)) { [HidScan]::CloseHandle($h) | Out-Null; continue }
  $caps = New-Object byte[] 64
  [HidScan]::HidP_GetCaps($ppd, $caps) | Out-Null
  $reportLen = @{ 0 = [BitConverter]::ToUInt16($caps,4); 2 = [BitConverter]::ToUInt16($caps,8) }   # input, feature
  $valCount  = @{ 0 = [BitConverter]::ToUInt16($caps,48); 2 = [BitConverter]::ToUInt16($caps,60) }
  foreach ($rt in 0, 2) {
    $n = $valCount[$rt]
    if ($n -eq 0) { continue }
    $len = [uint16]$n
    $vc = New-Object byte[] (72 * $n)
    [HidScan]::HidP_GetValueCaps($rt, $vc, [ref]$len, $ppd) | Out-Null
    for ($i = 0; $i -lt $len; $i++) {
      $o = 72 * $i
      $vPage = [BitConverter]::ToUInt16($vc, $o)
      $rid   = $vc[$o + 2]
      $u     = [BitConverter]::ToUInt16($vc, $o + 56)
      $match = $batteryUsages | Where-Object { $_.Page -eq $vPage -and $_.Usages -contains $u }
      if (-not $match) { continue }
      $buf = New-Object byte[] $reportLen[$rt]
      $buf[0] = $rid
      $ok = if ($rt -eq 0) { [HidScan]::HidD_GetInputReport($h, $buf, $buf.Length) }
            else            { [HidScan]::HidD_GetFeature($h, $buf, $buf.Length) }
      if (-not $ok) { continue }
      $val = [uint32]0
      if ([HidScan]::HidP_GetUsageValue($rt, $vPage, 0, $u, [ref]$val, $ppd, $buf, $buf.Length) -ne 0x00110000) { continue }
      $name = New-Object System.Text.StringBuilder 256
      [HidScan]::HidD_GetProductString($h, $name, 512) | Out-Null
      $collection = if ($name.Length) { $name.ToString() } else { '(no product string)' }
      [pscustomobject]@{
        Device     = Resolve-HidDeviceName $id $collection
        BatteryPct = $val
        Collection = $collection
        Source     = ('{0} report 0x{1:X2}, page 0x{2:X2} usage 0x{3:X2}' -f @('Input','','Feature')[$rt], $rid, $vPage, $u)
        InstanceId = $id
      }
    }
  }
  [HidScan]::HidD_FreePreparsedData($ppd) | Out-Null
  [HidScan]::CloseHandle($h) | Out-Null
}
