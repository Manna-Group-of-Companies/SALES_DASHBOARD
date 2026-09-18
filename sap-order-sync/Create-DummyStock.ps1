<#
.SYNOPSIS
  One zero-value Goods Receipt (InventoryGenEntries) seeding stock for the
  dummy component (I-14646) and the 10 test FG items (I-14636..I-14645),
  all into warehouse 07. Via the Service Layer.

.PARAMETER ConfigPath  config.json (same file Sync-SapOrders.ps1 uses). Required.
.PARAMETER DryRun      Print the POST body, write nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigPath,
    [switch] $DryRun
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO', [Parameter(Mandatory = $true)][string] $Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) { 'ERROR' { Write-Host $line -ForegroundColor Red } 'WARN' { Write-Host $line -ForegroundColor Yellow } default { Write-Host $line } }
}
function Get-JsonProp { param($Object, [string] $Name) if ($null -eq $Object) { return $null } $p = $Object.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null }

function Format-HttpError {
    param($ErrorRecord, [string] $Context)
    $status = $null
    try { if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) { $status = [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try { $s = $ErrorRecord.Exception.Response.GetResponseStream(); $r = New-Object System.IO.StreamReader($s); $body = $r.ReadToEnd(); $r.Close() } catch { }
    }
    $detail = $null
    if ($body) {
        try { $j = $body | ConvertFrom-Json; $e = Get-JsonProp $j 'error'
            if ($e) { $m = Get-JsonProp $e 'message'; if ($m) { $v = Get-JsonProp $m 'value'; $detail = if ($v) { "$v" } else { "$m" } }
                $c = Get-JsonProp $e 'code'; if ($detail -and $null -ne $c) { $detail = "$detail (code $c)" } }
        } catch { $detail = "$body" }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($status) { return "$Context [HTTP $status]: $detail" }
    return "${Context}: $detail"
}

function Enable-SapCertBypass {
    param([string] $SapHost)
    if (-not ([System.Management.Automation.PSTypeName]'SapCertBypass').Type) {
        Add-Type @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SapCertBypass {
    public static string AllowedHost;
    public static void Enable(string host) {
        AllowedHost = host;
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                if (errors == SslPolicyErrors.None) return true;
                HttpWebRequest req = sender as HttpWebRequest;
                return (req != null && string.Equals(req.RequestUri.Host, AllowedHost, StringComparison.OrdinalIgnoreCase));
            };
    }
}
'@
    }
    [SapCertBypass]::Enable($SapHost)
}

function New-SapWebSession {
    param([string] $BaseUrl, [string] $Username, [string] $Password, [string] $CompanyDb)
    $u = [System.Uri] $BaseUrl
    $splat = @{
        Method = 'Post'; Uri = "$BaseUrl/Login"
        Body = (@{ CompanyDB = $CompanyDb; UserName = $Username; Password = $Password } | ConvertTo-Json -Compress)
        ContentType = 'application/json'; UseBasicParsing = $true
        SessionVariable = 'sess'; ErrorAction = 'Stop'; TimeoutSec = 120
    }
    $resp = $null
    for ($try = 1; $try -le 4; $try++) {
        try { $resp = Invoke-WebRequest @splat; break }
        catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
            $retryable = ($code -eq 500 -or $code -eq 502 -or $code -eq 503 -or $code -eq 504 -or $null -eq $code)
            if (-not $retryable -or $try -eq 4) { throw (Format-HttpError $_ "SAP Login [$CompanyDb] (attempt $try/4)") }
            $wait = 5 * $try
            Write-Log WARN ("SAP login attempt {0}/4 failed (HTTP {1}); retry in {2}s" -f $try, $(if ($null -eq $code) { 'no response' } else { "$code" }), $wait)
            Start-Sleep -Seconds $wait
        }
    }
    $names = @()
    try { $names = @($sess.Cookies.GetCookies($u) | ForEach-Object { $_.Name }) } catch { }
    if ($names -notcontains 'B1SESSION') { throw "SAP Login [$CompanyDb]: no B1SESSION cookie." }
    Write-Log INFO ("SAP login OK [{0}] (cookies: {1})" -f $CompanyDb, ($names -join ','))
    return $sess
}

function Invoke-SapLogout {
    param([string] $BaseUrl, $Session)
    if (-not $Session) { return }
    try { $null = Invoke-RestMethod -Method Post -Uri "$BaseUrl/Logout" -WebSession $Session -TimeoutSec 60 -ErrorAction Stop; Write-Log INFO "SAP logout OK" }
    catch { Write-Log WARN ("SAP logout failed: {0}" -f $_.Exception.Message) }
}

function Invoke-SapPost {
    param([string] $BaseUrl, $Session, [string] $Entity, $Payload, [string] $Label)
    try { return Invoke-RestMethod -Method Post -Uri "$BaseUrl/$Entity" -Body ($Payload | ConvertTo-Json -Depth 8) -ContentType 'application/json' -WebSession $Session -TimeoutSec 180 -ErrorAction Stop }
    catch { throw (Format-HttpError $_ "SAP POST /$Entity ($Label)") }
}

# ---------------------------------------------------------------- config -------
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sap = $cfg.sap
$sapUrl = "$($sap.url)".TrimEnd('/')
$sapHost = ([System.Uri]$sapUrl).Host
$companyDb = "$($sap.company.company_db)"

# Empty-body 500 from the Service Layer on any POST carrying this header.
# Must precede the first request; it is read only at ServicePoint creation.
[System.Net.ServicePointManager]::Expect100Continue = $false
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
}
$prevCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$verify = $true; $vp = $sap.PSObject.Properties['verify_ssl']; if ($vp) { $verify = [bool]$vp.Value }
if (-not $verify) { Enable-SapCertBypass -SapHost $sapHost; Write-Log WARN ("TLS cert validation bypassed for '{0}' only." -f $sapHost) }

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add(@{ ItemCode = 'I-14646'; Quantity = 5000; WarehouseCode = '07'; UnitPrice = 0 })
foreach ($fg in @('I-14636','I-14637','I-14638','I-14639','I-14640','I-14641','I-14642','I-14643','I-14644','I-14645')) {
    [void]$lines.Add(@{ ItemCode = $fg; Quantity = 500; WarehouseCode = '07'; UnitPrice = 0 })
}
$payload = [ordered]@{
    DocDate       = (Get-Date).ToString('yyyy-MM-dd')
    Comments      = 'SYNC TEST dummy stock - zero value'
    DocumentLines = $lines
}

if ($DryRun) {
    Write-Log INFO ("WOULD POST /InventoryGenEntries:`n{0}" -f ($payload | ConvertTo-Json -Depth 8))
    return
}

$sess = $null
try {
    $sess = New-SapWebSession -BaseUrl $sapUrl -Username $sap.username -Password $sap.password -CompanyDb $companyDb
    $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'InventoryGenEntries' -Payload $payload -Label 'goods receipt'
    Write-Log INFO ("Goods Receipt DocNum {0} (DocEntry {1}) - {2} line(s) into warehouse 07." -f $r.DocNum, $r.DocEntry, @($lines).Count)
}
finally {
    Invoke-SapLogout -BaseUrl $sapUrl -Session $sess
    if ($PSVersionTable.PSVersion.Major -lt 6) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb }
}
