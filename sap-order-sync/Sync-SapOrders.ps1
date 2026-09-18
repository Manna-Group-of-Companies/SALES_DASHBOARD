<#
.SYNOPSIS
  ERPNext <-> SAP Business One (HITECH_PRETREADS_LIVE) order sync - SAP side.

.DESCRIPTION
  One ERPNext read, ONE SAP Service Layer login, then per order:

  Hi-Tech Pretreads is the FACTORY. It manufactures and bills Manna Treads and
  has NO visibility of the end customer. The SAP Sales Order created here carries
  ONLY: the fixed inter-company CardCode (20416 "Manna Treads Private
  Limited(GJ)"), dates, item codes, quantities, and the opaque ERPNext order
  name in NumAtCard. NOTHING that identifies the end customer - no name, code,
  address, territory, contact - goes anywhere in the document. That is a
  commercial boundary. End-customer traceability lives in ERPNext, keyed on the
  order name. ONE ERPNext order -> ONE Hi-Tech Sales Order; never aggregated.

  PASS A - orders newly approved for SAP
    In scope:  custom_po_status = "<gate>"  AND  custom_sap_sales_order empty
               AND docstatus < 2  (draft or submitted; neither app submits a
               Sales Order, so approval leaves it at docstatus 0 - the gate is
               custom_po_status, docstatus only drops a Frappe cancel)
    1. Re-read the order; abort this one if custom_sap_sales_order is no longer
       empty (never create the same SAP order twice).
    2. If stamp_erpnext_name_in is set, look for an existing SAP Order whose
       NumAtCard (or U_FreeText) already carries this ERPNext name - if found,
       ADOPT its DocNum instead of creating a second one (covers a crash between
       POST and write-back on a previous run).
    3. Build the SAP Sales Order:
         CardCode      <- order_sync.fixed_card_code  (20416, always - no lookup)
         DocDueDate    <- Sales Order.delivery_date (fallback transaction_date)
         line ItemCode <- items[].item_code           (already the SAP ItemCode)
         line Quantity <- items[].custom_total_weight  (KILOS, as approved)
                          -> fail the WHOLE order if a line's weight is missing/zero
         line UnitPrice<- items[].custom_rate_per_kg  (PER KILO, matching the
                          Quantity above - never items[].rate, which is per ROLL)
         line DiscountPercent <- items[].discount_percentage
                          Both ONLY if send_line_unit_price is true.

                          Turned ON 17 Sep 2026, on instruction: the SAP order
                          must carry the price the rep quoted and the manager
                          approved. It was off until then and SAP priced from
                          CardCode 20416's own Price List 01, which does not
                          agree - SAL-ORD-2026-00138 was approved at 24,165 and
                          landed in SAP (DocEntry 2884) at 21,523.34, about 11%
                          light.

                          The line AMOUNT is the thing that must survive. Where
                          rate x discount does not reconcile to it, the net rate
                          is sent flat and a WARN is logged; where there is no
                          price at all the whole order is refused rather than
                          letting SAP invent one.
       POST /Orders.
    4. IMMEDIATELY write back to ERPNext:  custom_sap_sales_order = DocNum,
       custom_sap_sales_order_status = SAP status verbatim,
       custom_sap_synced_at = now, custom_sap_sync_error = "" (cleared).

  PASS B - orders already in SAP, not yet delivered
    In scope:  custom_sap_sales_order set  AND  custom_sap_delivery_order empty
               AND docstatus < 2
    Using one scan of open ProductionOrders and one scan of recent DeliveryNotes:
      custom_sap_sales_order_status <- refreshed SAP status verbatim
      custom_sap_production_order    <- ProductionOrders.DocumentNumber of the
                                        production order linked to this SO -
                                        either a ProductionOrdersSalesOrderLines
                                        row with BaseAbsEntry = this SO's DocEntry,
                                        or ProductionOrderOrigin = bopooSalesOrder
                                        with ProductionOrderOriginEntry = DocEntry
      custom_sap_production_stage    <- current routing stage name
                                        (ProductionOrdersStages[].Name; when the
                                        PO has no routing stages, a label mapped
                                        from ProductionOrderStatus)
      custom_sap_delivery_order      <- DeliveryNotes.DocNum of a delivery whose
                                        line BaseType=17 / BaseEntry = this SO's
                                        DocEntry  (written to EVERY order the
                                        delivery carries, because every order is
                                        matched independently). NOTE this is the
                                        Hi-Tech DN into the Manna Treads godown,
                                        not a delivery to the end customer.
      custom_sap_delivery_date      <- that delivery's DocDueDate (config)
    custom_sap_synced_at is stamped on EVERY pass, changed or not.
    custom_sap_sync_error is cleared on any clean pass.

  NEVER written here: custom_production_status (the app derives it), and
  custom_sap_delivery_date from anywhere but a delivery order.

  ALWAYS logs out of the Service Layer in a finally (few licence seats).

.PARAMETER ConfigPath   Required. JSON config (see config.example.json). Never holds creds in source.
.PARAMETER DryRun       Read everything, write NOTHING, print the SAP payload and the ERPNext
                        write it WOULD make, per order. RUN THIS FIRST.
.PARAMETER Limit        Process at most N orders in EACH pass (ordered by name, stable).
                        0 = no cap. First real run: -Limit 2.
.PARAMETER ResultJsonPath  Small JSON run summary for the poller to report back.

.EXAMPLE
  .\Sync-SapOrders.ps1 -ConfigPath .\config.json -DryRun
.EXAMPLE
  .\Sync-SapOrders.ps1 -ConfigPath .\config.json -Limit 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ConfigPath,

    [switch] $DryRun,

    [int] $Limit = 0,

    [string] $ResultJsonPath
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:LogFile          = $null
$script:StartedAt        = Get-Date
$script:SapSkipCert      = $false
$script:PrevCertCallback = $null
$script:ErpBaseUrl       = $null
$script:ErpAuthHeader    = $null

$script:Result = [ordered]@{
    exitCode          = 1
    dryRun            = [bool]$DryRun
    company           = $null
    inScopeNew        = 0
    created           = 0
    adopted           = 0
    createFailed      = 0
    openPolled        = 0
    productionMatched = 0
    stagesWritten     = 0
    linesWritten      = 0
    linesCorrected    = 0
    linesRemoved      = 0
    stagesCleared     = 0
    repUnmatched      = 0
    deliveriesWritten = 0
    writeErrors       = 0
    failures          = 0
    changed           = 0
    summary           = $null
    error             = $null
    startedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    finishedAt        = $null
    elapsedSec        = 0
}

# ERPNext Sales Order fieldnames this job writes (single source of truth).
$script:F_SO       = 'custom_sap_sales_order'
$script:F_SO_STAT  = 'custom_sap_sales_order_status'
$script:F_PROD     = 'custom_sap_production_order'
$script:F_STAGE    = 'custom_sap_production_stage'
$script:F_DELIV    = 'custom_sap_delivery_order'
$script:F_DELIV_DT = 'custom_sap_delivery_date'
$script:F_SYNCED   = 'custom_sap_synced_at'
$script:F_ERR      = 'custom_sap_sync_error'

$SO_DOCTYPE_ENC = [uri]::EscapeDataString('Sales Order')   # doctype names with spaces MUST be encoded
$SAP_BASETYPE_SALESORDER = 17

# --------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string] $Message
    )
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Get-JsonProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-Number {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    $s = "$Value".Trim()
    if ($s -eq '') { return 0.0 }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref] $d)) { return $d }
    return 0.0
}

function Read-JsonConfig {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Config file is not valid JSON ($Path): $($_.Exception.Message)"
    }
}

function Get-RequiredString {
    param($Object, [string] $Name, [string] $PathLabel)
    $s = "$(Get-JsonProp $Object $Name)".Trim()
    if ($s -eq '') {
        throw ("config: '{0}.{1}' is missing or empty - this script does not default it." -f $PathLabel, $Name)
    }
    if ($s -match '(?i)PUT_|REPLACE|PLACEHOLDER|CHANGE_?ME|XXXX|^<.+>$') {
        throw ("config: '{0}.{1}' still holds a placeholder value ('{2}')." -f $PathLabel, $Name, $s)
    }
    return $s
}

function Get-OptionalString {
    param($Object, [string] $Name, [string] $Default = '')
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return $Default }
    $s = "$($p.Value)".Trim()
    if ($s -eq '') { return $Default }
    return $s
}

function Get-OptionalInt {
    param($Object, [string] $Name, [int] $Default)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value -or "$($p.Value)".Trim() -eq '') { return $Default }
    return [int]$p.Value
}

function Get-OptionalBool {
    # JSON booleans arrive as [bool] from ConvertFrom-Json; also tolerate
    # true/false/1/0/yes/no/on/off as strings. Anything else -> the default.
    param($Object, [string] $Name, [bool] $Default)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return $Default }
    if ($p.Value -is [bool]) { return [bool]$p.Value }
    $s = "$($p.Value)".Trim().ToLowerInvariant()
    if ($s -eq '') { return $Default }
    if ($s -in @('true', '1', 'yes', 'on'))  { return $true }
    if ($s -in @('false', '0', 'no', 'off')) { return $false }
    return $Default
}

function Format-HttpError {
    # The useful reason is in the RESPONSE BODY, not the status line.
    # SAP B1:  { "error": { "code": n, "message": { "value": "..." } } }
    # Frappe:  { "exception": "...", "message": "...", "_server_messages": "..." }  (often on a 417)
    param($ErrorRecord, [string] $Context)

    $status = $null
    try {
        if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
            $status = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch { }

    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }

    $detail = $null
    if ($body) {
        try {
            $j = $body | ConvertFrom-Json
            $err = Get-JsonProp $j 'error'
            if ($err) {
                $m = Get-JsonProp $err 'message'
                if ($m) {
                    $v = Get-JsonProp $m 'value'
                    if ($v) { $detail = "$v" } else { $detail = "$m" }
                }
                $code = Get-JsonProp $err 'code'
                if ($detail -and $null -ne $code) { $detail = "$detail (code $code)" }
            }
            if (-not $detail) { $ex = Get-JsonProp $j 'exception'; if ($ex) { $detail = "$ex" } }
            if (-not $detail) {
                $sm = Get-JsonProp $j '_server_messages'
                if ($sm) { $detail = "$sm" }
            }
            if (-not $detail) { $fm = Get-JsonProp $j 'message';   if ($fm) { $detail = "$fm" } }
        } catch {
            $detail = "$body"
        }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 700) { $detail = $detail.Substring(0, 700) + ' ...' }
    $prefix = $Context
    if ($status) { $prefix = "$Context [HTTP $status]" }
    return ('{0}: {1}' -f $prefix, $detail)
}

# --------------------------------------------------------------------------------
# ERPNext
# --------------------------------------------------------------------------------

function Invoke-ErpApi {
    param(
        [string] $Method,
        [string] $Path,      # already-encoded path, e.g. /api/resource/Sales%20Order/NAME
        [string] $Query,     # already URL-encoded, no leading '?'
        $Body                # hashtable -> JSON, or $null
    )
    $uri = $script:ErpBaseUrl.TrimEnd('/') + $Path
    if ($Query) { $uri = $uri + '?' + $Query }

    $splat = @{
        Method      = $Method
        Uri         = $uri
        Headers     = @{ Authorization = $script:ErpAuthHeader }
        ErrorAction = 'Stop'
        TimeoutSec  = 120
    }
    if ($null -ne $Body) {
        # UTF-8 BYTES, not a string. PS 5.1's ConvertTo-Json emits non-ASCII
        # literally rather than as \uXXXX, and Invoke-RestMethod then encodes a
        # string body with the default codepage - so anything outside ASCII
        # arrives mangled. Caught on 18 Sep 2026 writing a rebuilt packing note:
        # ERPNext stored "3 rolls <?> 144.00 kg" where the middle dot should be.
        # Every non-ASCII character this script has ever written was affected;
        # it had simply never written one before.
        $json              = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $splat.Body        = [System.Text.Encoding]::UTF8.GetBytes($json)
        $splat.ContentType = 'application/json; charset=utf-8'
    }
    try {
        return Invoke-RestMethod @splat
    } catch {
        throw (Format-HttpError $_ "ERPNext $Method $Path")
    }
}

function Get-ErpList {
    param([string] $Filters, [string[]] $Fields)
    $fieldsJson = '[' + (($Fields | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
    $query = 'fields='  + [uri]::EscapeDataString($fieldsJson) +
             '&filters=' + [uri]::EscapeDataString($Filters) +
             '&limit_page_length=0'
    $resp = Invoke-ErpApi -Method 'GET' -Path "/api/resource/$SO_DOCTYPE_ENC" -Query $query
    # A zero-row result is {"data":[]} - a normal, common state (no new approved
    # orders since the last run). Only a genuinely absent 'data' key is an error;
    # Get-JsonProp would collapse an empty array to $null, so test the property.
    if ($null -eq $resp -or -not $resp.PSObject.Properties['data']) {
        throw "ERPNext returned no 'data' array for filter $Filters"
    }
    return @($resp.data)
}

function Get-ErpSalesOrder {
    param([string] $Name)
    $resp = Invoke-ErpApi -Method 'GET' -Path ("/api/resource/$SO_DOCTYPE_ENC/" + [uri]::EscapeDataString($Name))
    $doc  = Get-JsonProp $resp 'data'
    if ($null -eq $doc) { throw "ERPNext returned no 'data' for Sales Order '$Name'" }
    return $doc
}

# (No customer lookup: the Hi-Tech Sales Order always uses the fixed
# inter-company CardCode. custom_bp_code belongs to the out-of-scope stage-two
# push into MANNA_TREADS_LIVE.)

function Update-ErpSalesOrder {
    param([string] $Name, [hashtable] $Fields)
    $null = Invoke-ErpApi -Method 'PUT' `
        -Path ("/api/resource/$SO_DOCTYPE_ENC/" + [uri]::EscapeDataString($Name)) `
        -Body $Fields
}

<#
.SYNOPSIS
  One ERPNext Sales Order Item -> one SAP DocumentLine.

.DESCRIPTION
  Its own function so it can be tested against real orders without pushing
  anything - see Test-OrderLinePricing.ps1. PASS A calls nothing else to build
  a line.

  THE UNIT TRAP. Quantity is custom_total_weight, in KILOS, so the price must
  be per kilo too. ERPNext's own `rate` is per ROLL: SAL-ORD-2026-00138 line 1
  is qty 1 at rate 8100, which is 32.4 kg at 250/kg. `rate` was once the
  fallback here and would have priced that line at 8100 the kilo.

  NO DISCOUNT EVER REACHES SAP. Decided 17 Sep 2026: the discount feature was
  taken out of both apps and the sales team types the rate AFTER discount, so
  what is quoted is already net. DiscountPercent is therefore always 0 and the
  price is derived from the line AMOUNT, which is the figure the manager
  actually approved:

      UnitPrice = amount / custom_total_weight

  That also prices the handful of legacy lines that still carry a
  discount_percentage - SAL-ORD-2026-00135 has 25/kg with 10% off and a real
  22.50/kg, and amount/weight gives 22.50 without needing to know about the
  discount at all. custom_rate_per_kg is read only to warn when the two
  disagree, which is the signature of exactly those legacy rows.

.OUTPUTS
  @{ Line = <hashtable for DocumentLines>; Error = <string, or $null> }
#>
function New-SapOrderLine {
    param(
        [Parameter(Mandatory = $true)] $Item,
        [bool]   $SendUnitPrice = $false,
        [string] $OrderName = '',
        [int]    $Index = 0,
        [string] $Warehouse = ''
    )

    $ic = "$(Get-JsonProp $Item 'item_code')".Trim()
    $wt = ConvertTo-Number (Get-JsonProp $Item 'custom_total_weight')
    if ($ic -eq '') { return @{ Line = $null; Error = "line $Index has no item_code." } }
    if ($wt -le 0)  { return @{ Line = $null; Error = "line $Index (item $ic): custom_total_weight is missing or zero - refusing to guess the SAP quantity." } }

    $line = @{ ItemCode = $ic; Quantity = [double]$wt }
    # Name the warehouse, or SAP falls back to its own default and commits the
    # line somewhere the goods are not. Found 18 September 2026: every order
    # this sync had created committed stock to warehouse 01 while all the
    # finished goods sat in 07, so 07 read as free and 01 read as oversold.
    # Company-wide totals netted out, which is why the stock figures looked
    # right while the per-warehouse ones were wrong in both directions.
    if ("$Warehouse".Trim() -ne '') { $line.WarehouseCode = "$Warehouse".Trim() }
    if (-not $SendUnitPrice) { return @{ Line = $line; Error = $null } }

    $amount = ConvertTo-Number (Get-JsonProp $Item 'amount')
    if ($amount -le 0) {
        # 0 books a free line, and letting SAP fill from its own price list is
        # the exact thing this option exists to stop.
        return @{ Line = $null; Error = "line $Index (item $ic): no amount - refusing to push an order whose price SAP would have to invent." }
    }

    $netPerKg = $amount / $wt

    # Sanity check only. On a current order the quoted rate IS the net rate and
    # these agree; a gap means the line still carries a legacy
    # discount_percentage, which the figure above has already absorbed.
    $ratePerKg = ConvertTo-Number (Get-JsonProp $Item 'custom_rate_per_kg')
    if ($ratePerKg -gt 0) {
        $tol = 0.005 * [math]::Max($netPerKg, 1)
        if ([math]::Abs($ratePerKg - $netPerKg) -gt $tol) {
            Write-Log WARN ("PASS A {0}: line {1} (item {2}) quotes {3}/kg but the amount works out at {4}/kg (discount {5}%) - sending {4}/kg, which is what was approved." -f `
                $OrderName, $Index, $ic, $ratePerKg, [math]::Round($netPerKg, 4), (ConvertTo-Number (Get-JsonProp $Item 'discount_percentage')))
        }
    }

    $line.UnitPrice       = [double][math]::Round($netPerKg, 6)
    $line.DiscountPercent = 0.0

    return @{ Line = $line; Error = $null }
}

# --------------------------------------------------------------------------------
# SAP Business One Service Layer
# --------------------------------------------------------------------------------

function Enable-SapCertBypass {
    # Host-scoped bad-cert acceptance for Windows PowerShell 5.1, as a COMPILED
    # delegate (a scriptblock callback breaks TLS for other hosts on 5.1 - it
    # would also take out the ERPNext HTTPS calls).
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
    # Log in and hand back a WebRequestSession whose cookie jar carries B1SESSION
    # and ROUTEID (load-balancer stickiness - the SL is clustered). Rely on the
    # cookie CONTAINER, never a hand-built Cookie header (5.1 silently drops it).
    param(
        [string] $BaseUrl, [string] $Username, [string] $Password,
        [string] $CompanyDb, [string] $CompanyName, [bool] $UseSkipCert
    )
    $u = [System.Uri] $BaseUrl
    $loginSplat = @{
        Method          = 'Post'
        Uri             = "$BaseUrl/Login"
        Body            = (@{ CompanyDB = $CompanyDb; UserName = $Username; Password = $Password } | ConvertTo-Json -Compress)
        ContentType     = 'application/json'
        UseBasicParsing = $true
        SessionVariable = 'sess'
        ErrorAction     = 'Stop'
        TimeoutSec      = 120
    }
    if ($UseSkipCert) { $loginSplat.SkipCertificateCheck = $true }

    # Retry a few times with backoff for a transient 5xx (a node warming up).
    # A 400/401 (bad credentials / company) is final.
    # NOT retryable, despite looking transient: an empty-body 500 returned in
    # ~10ms means the request carried 'Expect: 100-continue', which the Service
    # Layer rejects outright. Every retry re-sends the same header, so all four
    # attempts fail identically. Expect100Continue is disabled at the top of
    # this script; if that line is ever lost, this loop will burn 30 seconds
    # before reporting a failure it could never have recovered from.
    $resp = $null
    $maxTries = 4
    for ($try = 1; $try -le $maxTries; $try++) {
        try { $resp = Invoke-WebRequest @loginSplat; break }
        catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            }
            $retryable = ($code -eq 500 -or $code -eq 502 -or $code -eq 503 -or $code -eq 504 -or $null -eq $code)
            if (-not $retryable -or $try -eq $maxTries) {
                throw (Format-HttpError $_ "SAP Login [$CompanyName / $CompanyDb] (attempt $try/$maxTries)")
            }
            $wait = 5 * $try
            Write-Log WARN ("SAP login attempt {0}/{1} failed (HTTP {2}); retrying in {3}s" -f $try, $maxTries, $(if ($null -eq $code) { 'no response' } else { "$code" }), $wait)
            Start-Sleep -Seconds $wait
        }
    }

    function Get-JarNames { param($s) try { @($s.Cookies.GetCookies($u) | ForEach-Object { $_.Name }) } catch { @() } }
    $names = Get-JarNames $sess
    if ($names -notcontains 'B1SESSION') {
        $rawHeaders = @()
        try { $rawHeaders = @($resp.BaseResponse.Headers.GetValues('Set-Cookie')) } catch { }
        if (-not $rawHeaders -or $rawHeaders.Count -eq 0) { $rawHeaders = @("$($resp.Headers['Set-Cookie'])") }
        foreach ($h in $rawHeaders) {
            if (-not "$h".Trim()) { continue }
            foreach ($piece in [regex]::Split("$h", ',(?=\s*[^=;,\s]+=)')) {
                try { $sess.Cookies.SetCookies($u, $piece.Trim()) } catch { }
            }
        }
        $names = Get-JarNames $sess
    }
    if ($names -notcontains 'B1SESSION') {
        $sid = $null
        try { $sid = ($resp.Content | ConvertFrom-Json).SessionId } catch { }
        if ($sid) {
            try { $sess.Cookies.Add((New-Object System.Net.Cookie('B1SESSION', "$sid", '/', $u.Host))); $names = Get-JarNames $sess } catch { }
        }
    }
    if ($names -notcontains 'B1SESSION') {
        throw "SAP Login [$CompanyName / $CompanyDb]: authenticated but could not obtain a B1SESSION cookie or SessionId."
    }
    Write-Log INFO ("SAP login OK [{0} / {1}] (cookies: {2})" -f $CompanyName, $CompanyDb, ($names -join ','))
    return $sess
}

function Invoke-SapLogout {
    param([string] $BaseUrl, $Session, [bool] $UseSkipCert)
    if (-not $Session) { return }
    try {
        $splat = @{ Method = 'Post'; Uri = "$BaseUrl/Logout"; WebSession = $Session; ErrorAction = 'Stop'; TimeoutSec = 60 }
        if ($UseSkipCert) { $splat.SkipCertificateCheck = $true }
        $null = Invoke-RestMethod @splat
        Write-Log INFO "SAP logout OK"
    } catch {
        Write-Log WARN ("SAP logout failed: {0}" -f $_.Exception.Message)
    }
}

function Invoke-SapGet {
    param([string] $BaseUrl, $Session, [string] $RelUrl, [int] $PageSize, [bool] $UseSkipCert, [string] $Label)
    # GET an OData collection, following odata.nextLink to the end.
    # ArrayList, not Generic.List[object]: callers wrap the result in @()
    # (e.g. PASS A's adopt scan), which throws "Argument types do not match"
    # over a generic list on this PS 5.1 build.
    $rows  = New-Object System.Collections.ArrayList
    $pages = 0
    $next  = if ($RelUrl -match '^https?://') { $RelUrl } else { "$BaseUrl/$RelUrl" }
    while ($next) {
        $pages++
        $splat = @{
            Method = 'Get'; Uri = $next
            Headers = @{ Prefer = "odata.maxpagesize=$PageSize" }
            WebSession = $Session; ErrorAction = 'Stop'; TimeoutSec = 180
        }
        if ($UseSkipCert) { $splat.SkipCertificateCheck = $true }
        try { $resp = Invoke-RestMethod @splat }
        catch { throw (Format-HttpError $_ "SAP GET $Label page $pages") }

        # A collection GET always carries a 'value' property, even when it is
        # []. Get-JsonProp collapses an empty array to $null, so test the
        # property itself - otherwise a zero-row result falls through to the
        # single-entity branch and the response ENVELOPE gets added as a fake
        # row (which then "adopts" a non-existent Order with a blank DocNum).
        if ($resp -and $resp.PSObject.Properties['value']) {
            foreach ($r in @($resp.value)) { [void]$rows.Add($r) }
        }
        else { [void]$rows.Add($resp) }   # single-entity GET (no 'value' wrapper)

        $link = Get-JsonProp $resp 'odata.nextLink'
        if (-not $link) { $link = Get-JsonProp $resp '@odata.nextLink' }
        if ($link) {
            $link = "$link"
            if ($link -match '^https?://') { $next = $link }
            elseif ($link.StartsWith('/')) { $uu = [System.Uri]$BaseUrl; $next = ('{0}://{1}{2}' -f $uu.Scheme, $uu.Authority, $link) }
            else { $next = "$BaseUrl/" + $link }
        } else { $next = $null }
    }
    if ($pages -gt 1) { Write-Log INFO ("SAP GET {0}: {1} row(s) over {2} page(s)" -f $Label, $rows.Count, $pages) }
    return $rows
}

function New-SapSalesOrder {
    param([string] $BaseUrl, $Session, [hashtable] $Payload, [bool] $UseSkipCert)
    $splat = @{
        Method = 'Post'; Uri = "$BaseUrl/Orders"
        Body = ($Payload | ConvertTo-Json -Depth 8)
        ContentType = 'application/json'
        WebSession = $Session; ErrorAction = 'Stop'; TimeoutSec = 180
    }
    if ($UseSkipCert) { $splat.SkipCertificateCheck = $true }
    try { return Invoke-RestMethod @splat }
    catch { throw (Format-HttpError $_ "SAP POST /Orders") }
}

function Get-SapSalesPersonMap {
    param([string] $BaseUrl, $Session, [int] $PageSize, [bool] $UseSkipCert)
    # Lowercased sales-employee name -> SalesEmployeeCode, for the ACTIVE ones.
    #
    # ERPNext names the rep on the order ('Test Rep'); SAP wants a number. The
    # only thing the two sides share is the name, which is why every SAP sales
    # employee here was created with EXACTLY the ERPNext `Sales Person` spelling.
    # Rename one on either side and orders stop being tagged - the sync says so
    # in the log rather than guessing at a near-match.
    $map = @{}
    $rel = 'SalesPersons?$select=SalesEmployeeCode,SalesEmployeeName,Active&$orderby=SalesEmployeeCode'
    foreach ($r in (Invoke-SapGet -BaseUrl $BaseUrl -Session $Session -RelUrl $rel -PageSize $PageSize -UseSkipCert $UseSkipCert -Label 'SalesPersons')) {
        if ("$(Get-JsonProp $r 'Active')" -ne 'tYES') { continue }
        $code = "$(Get-JsonProp $r 'SalesEmployeeCode')".Trim()
        $nm   = "$(Get-JsonProp $r 'SalesEmployeeName')".Trim()
        # -1 is SAP's own '-No Sales Employee-' placeholder, not a person.
        if ($nm -eq '' -or $code -eq '' -or $code -eq '-1') { continue }
        $key = $nm.ToLowerInvariant()
        if ($map.ContainsKey($key)) {
            # Two employees, one name: the lower code wins (orderby above makes
            # that deterministic), but say so - whichever it picks may be wrong.
            Write-Log WARN ("SAP has more than one active sales employee named '{0}' (codes {1} and {2}); orders will be tagged {1}." -f $nm, $map[$key], $code)
            continue
        }
        $map[$key] = [int]$code
    }
    return $map
}

function Resolve-SapSalesPersonCode {
    param([string] $RepName, [hashtable] $Map, [string] $Fallback)
    # Pure: @{ Code = <int|$null>; Warning = <string> }. A $null Code means send
    # no SalesPersonCode at all and let SAP apply its own default (-1).
    #
    # An unknown rep is a WARNING, never a failure. An order sitting outside SAP
    # because nobody added a sales employee is worse than one inside it with the
    # employee blank: the first stops the factory, the second is a field to fill
    # in. The warning names the rep and is counted into the run summary, so it
    # cannot go unnoticed for long either.
    $fb = $null
    if ("$Fallback".Trim() -ne '') { $fb = [int]"$Fallback".Trim() }

    $rep = "$RepName".Trim()
    # 'null' is an unset Frappe Link read back through naive interpolation - a
    # real rep name, never. Same guard as the delivery-order one in the apps.
    if ($rep -eq '' -or $rep -eq 'null') { return @{ Code = $fb; Warning = '' } }

    $key = $rep.ToLowerInvariant()
    if ($Map -and $Map.ContainsKey($key)) { return @{ Code = [int]$Map[$key]; Warning = '' } }

    $note = if ($null -eq $fb) { 'the SAP order will carry no sales employee' } else { "falling back to code $fb" }
    return @{
        Code    = $fb
        Warning = ("no active SAP sales employee named '{0}' - {1}. Add one in SAP (Administration > Setup > General > Sales Employees) spelled exactly that way" -f $rep, $note)
    }
}

# --------------------------------------------------------------------------------
# Derivations
# --------------------------------------------------------------------------------

function Resolve-SoStatus {
    param($Order)
    if ("$(Get-JsonProp $Order 'Cancelled')" -eq 'tYES') { return 'bost_Cancelled' }
    return "$(Get-JsonProp $Order 'DocumentStatus')"
}

function Resolve-CurrentStage {
    param($Po, $Labels, [string] $StageSource)
    $stages = Get-JsonProp $Po 'ProductionOrdersStages'
    if ($StageSource -eq 'routing_stages' -and $stages -and @($stages).Count -gt 0) {
        $ordered = @($stages) | Sort-Object { [int](ConvertTo-Number (Get-JsonProp $_ 'SequenceNumber')) }
        $active  = $ordered | Where-Object { -not "$(Get-JsonProp $_ 'EndDate')".Trim() } | Select-Object -First 1
        if ($active) { return "$(Get-JsonProp $active 'Name')".Trim() }
        $last = $ordered | Select-Object -Last 1
        if ($last) { return "$(Get-JsonProp $last 'Name')".Trim() }
    }
    $st  = "$(Get-JsonProp $Po 'ProductionOrderStatus')"
    $lbl = Get-JsonProp $Labels $st
    if ($lbl) { return "$lbl" }
    return $st
}

function Select-LeastAdvancedPo {
    # Of several production orders covering the same thing, report the one the
    # floor has got least far with. An order is only Ready when everything for
    # it is finished - reporting the most advanced would tell a rep an order is
    # made while part of it is still in a press.
    # Cancelled orders are ignored entirely; they cover nothing.
    param($Pos)
    $rank = @{ 'boposPlanned' = 0; 'boposReleased' = 1; 'boposClosed' = 2 }
    $best = $null; $bestRank = 99
    foreach ($p in $Pos) {
        $st = "$(Get-JsonProp $p 'ProductionOrderStatus')"
        if ($st -eq 'boposCancelled') { continue }
        $r = if ($rank.ContainsKey($st)) { $rank[$st] } else { 1 }   # unknown = In Production
        if ($r -lt $bestRank) { $bestRank = $r; $best = $p }
    }
    return $best
}

function Add-PoToMap {
    param($Map, [string] $Key, $Po)
    if ($Key -eq '' -or $Key -eq '0') { return }
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = New-Object System.Collections.ArrayList }
    [void]$Map[$Key].Add($Po)
}

function Resolve-SoEntryByDocNumAndItem {
    param($Candidates, [string] $ItemCode)
    # A production order raised by hand carries the sales order NUMBER and no
    # entry: type 406 into the Sales Order field and SAP fills
    # ProductionOrderOriginNumber = 406, leaving ProductionOrderOriginEntry
    # null. DocNum is not unique in this database - 406 is four different sales
    # orders - so the number alone cannot say which one.
    #
    # The item breaks the tie. A production order makes ONE item, and that item
    # has to be on the order it is for. Returns the DocEntry only when exactly
    # one candidate carries it; anything else is ambiguous and refused, because
    # guessing here attaches a live production order to a stranger's order.
    #
    # Returns @{ Entry = <string, '' when refused>; Reason = <string> }.
    if ("$ItemCode".Trim() -eq '') { return @{ Entry = ''; Reason = 'the production order names no item' } }
    $hits = @()
    foreach ($c in $Candidates) {
        foreach ($l in @(Get-JsonProp $c 'DocumentLines')) {
            if ("$(Get-JsonProp $l 'ItemCode')".Trim() -eq "$ItemCode".Trim()) {
                $de = "$(Get-JsonProp $c 'DocEntry')".Trim()
                if ($de -ne '' -and $de -ne '0') { $hits += $de }
                break
            }
        }
    }
    $hits = @($hits | Select-Object -Unique)
    if ($hits.Count -eq 1) { return @{ Entry = "$($hits[0])"; Reason = '' } }
    if ($hits.Count -eq 0) { return @{ Entry = ''; Reason = 'no sales order with that DocNum carries the item' } }
    return @{ Entry = ''; Reason = ("{0} sales orders with that DocNum carry the item" -f $hits.Count) }
}

function Update-ErpOrderLine {
    # Child rows cannot go through the document PUT: sending an 'items' array
    # replaces the whole table, and on an India-Compliance site that re-runs tax
    # and total calculation. frappe.client.set_value touches one row only.
    param([string] $RowName, [hashtable] $Fields)
    $null = Invoke-ErpApi -Method 'POST' -Path '/api/method/frappe.client.set_value' -Body @{
        doctype   = 'Sales Order Item'
        name      = $RowName
        fieldname = $Fields
    }
}

function Remove-ErpOrderLine {
    # Deleting a child row IS allowed through frappe.client.delete, and the
    # parent recalculates its totals afterwards - both verified against the
    # live site on 17 Sep 2026. Deleting the LAST row is refused by Frappe
    # itself (MandatoryError: items), which is why the planner never asks.
    param([string] $RowName)
    $null = Invoke-ErpApi -Method 'POST' -Path '/api/method/frappe.client.delete' -Body @{
        doctype = 'Sales Order Item'
        name    = $RowName
    }
}

<#
.SYNOPSIS
  The packing note for a corrected line, or $null when it cannot be rebuilt.

.DESCRIPTION
  Mirrors `computeLine` in client/src/domain/productRules.ts exactly, and only
  for the two roll-based families where the shape is a simple two-part string:

      "5 rolls + 4 loose belts - 162.40 kg (avg)"      PCTR  (with " (avg)")
      "3 rolls - 90.00 kg"                             CTR   (no belts, no avg)

  BG and VS build their note from a packing breakdown that is a genuine rule,
  not a format, and reproducing it here would be that rule's THIRD
  implementation - the exact thing shared/README.md exists to prevent. For
  those this returns $null and the planner refuses the line rather than leaving
  a stale note beside corrected figures.

  The middle dot is built from its code point on purpose: this file is ASCII,
  and a literal would either mangle under PS 5.1 or change the file's encoding.
#>
function New-ErpPackingNote {
    param([string] $Category, [double] $Rolls, [int] $Belts, [double] $WeightKg)

    $cat = "$Category".Trim().ToUpperInvariant()
    if ($cat -ne 'PCTR' -and $cat -ne 'CTR') { return $null }

    $parts = New-Object System.Collections.ArrayList
    $r = [int][math]::Round($Rolls, 0)
    if ($r -gt 0) { [void]$parts.Add(("{0} roll{1}" -f $r, $(if ($r -eq 1) { '' } else { 's' }))) }
    if ($cat -eq 'PCTR' -and $Belts -gt 0) {
        [void]$parts.Add(("{0} loose belt{1}" -f $Belts, $(if ($Belts -eq 1) { '' } else { 's' })))
    }
    if ($parts.Count -eq 0) { return $null }

    $dot    = [string][char]0x00B7
    $suffix = if ($cat -eq 'PCTR') { ' (avg)' } else { '' }
    return ("{0} {1} {2} kg{3}" -f ($parts -join ' + '), $dot, $WeightKg.ToString('F2'), $suffix)
}

<#
.SYNOPSIS
  What has to change in ERPNext so its lines match SAP's. Plans only; writes
  nothing.

.DESCRIPTION
  Its own function so it can be tested against real orders without touching
  anything - see Test-LineReconcile.ps1.

  SAP is the record for an approved order. The manufacturing team reduce or
  drop a line that has not been made, and the app follows. Quantities are
  compared in KILOS, because kilos are what the sync sends as SAP's Quantity
  and what ERPNext keeps in custom_total_weight.

  REFUSING IS A RESULT. Four cases plan nothing and say why, because a wrong
  correction here silently rewrites a customer's order:

    * SAP returned no lines at all. That is the signature of a failed or
      partial read, not of an order somebody emptied.
    * The same item appears twice on either side. Matching is by item code, so
      two rows for one code cannot be told apart and neither may be guessed at.
    * Every ERPNext line would be removed. Frappe refuses to delete the last
      row anyway (MandatoryError: items); an order that has genuinely lost
      everything wants a human, not a sync.
    * The line's family is not PCTR or CTR, so its packing note cannot be
      rebuilt - see New-ErpPackingNote. Corrected figures beside a stale note
      are worse than an untouched line.

  CLOSED IS AMBIGUOUS, AND THE DELIVERY NOTE IS THE TIE-BREAKER. A Sales Order
  line reads LineStatus 'bost_Close' with RemainingOpenQuantity 0 in two
  completely different situations: it was fully delivered, or somebody closed
  the row to drop it. There is no DeliveredQuantity on a Service Layer order
  line to tell them apart - checked against the live DB, the fields are
  Quantity, RemainingOpenQuantity and LineStatus and nothing else.

  So -DeliveredItems is required: the item codes a delivery note actually
  carried for this order, which PASS B already has in $dnByEntryItem. Closed
  WITH a delivery is a finished line and is left alone. Closed WITHOUT one is
  the manufacturing team dropping an item, and the ERPNext row goes.

  Getting this backwards would delete the lines the customer has already been
  sent.

.OUTPUTS
  @{ Abort = <string or $null>; Actions = <ArrayList of action hashtables> }
  Each action: @{ Action = 'reduce'|'remove'|'skip'; RowName; ItemCode; Fields; Note }
#>
function Get-ErpLineCorrections {
    param(
        [Parameter(Mandatory = $true)] $SapLines,
        [Parameter(Mandatory = $true)] $ErpItems,
        [hashtable] $DeliveredItems = @{},
        [double] $Tolerance = 0.001
    )

    $out = @{ Abort = $null; Actions = (New-Object System.Collections.ArrayList) }

    $sap = @($SapLines)
    $erp = @($ErpItems)
    if ($sap.Count -eq 0) {
        $out.Abort = 'SAP returned no lines for this order - treating as an unreadable order, not an emptied one.'
        return $out
    }
    if ($erp.Count -eq 0) { return $out }

    # Kilos per item on each side, whether SAP still has the item open, and a
    # note of any item that appears twice.
    $sapKg = @{}; $sapDup = @{}; $sapOpen = @{}
    foreach ($l in $sap) {
        $code = "$(Get-JsonProp $l 'ItemCode')".Trim()
        if ($code -eq '') { continue }
        $qty    = ConvertTo-Number (Get-JsonProp $l 'Quantity')
        $isOpen = ("$(Get-JsonProp $l 'LineStatus')".Trim() -ne 'bost_Close')
        if ($sapKg.ContainsKey($code)) {
            $sapDup[$code] = $true
            $sapKg[$code]  = $sapKg[$code] + $qty
            if ($isOpen) { $sapOpen[$code] = $true }
        } else {
            $sapKg[$code]   = $qty
            $sapOpen[$code] = $isOpen
        }
    }
    $erpSeen = @{}; $erpDup = @{}
    foreach ($it in $erp) {
        $code = "$(Get-JsonProp $it 'item_code')".Trim()
        if ($code -eq '') { continue }
        if ($erpSeen.ContainsKey($code)) { $erpDup[$code] = $true }
        $erpSeen[$code] = $true
    }

    $removals = 0
    foreach ($it in $erp) {
        $code    = "$(Get-JsonProp $it 'item_code')".Trim()
        $rowName = "$(Get-JsonProp $it 'name')".Trim()
        $act     = @{ Action = 'skip'; RowName = $rowName; ItemCode = $code; Fields = @{}; Note = '' }

        if ($code -eq '' -or $rowName -eq '') {
            $act.Note = 'line has no item_code or row name.'
            [void]$out.Actions.Add($act); continue
        }
        if ($sapDup.ContainsKey($code) -or $erpDup.ContainsKey($code)) {
            $act.Note = "item $code appears on more than one line - cannot tell the rows apart by item code, so neither is touched."
            [void]$out.Actions.Add($act); continue
        }

        $erpKg = ConvertTo-Number (Get-JsonProp $it 'custom_total_weight')

        if (-not $sapKg.ContainsKey($code)) {
            $act.Action = 'remove'
            $act.Note   = "dropped in SAP (ERPNext still has $erpKg kg)."
            $removals++
            [void]$out.Actions.Add($act); continue
        }

        # Closed in SAP. Delivered, or dropped? Only the delivery note knows.
        if (-not $sapOpen[$code]) {
            if ($DeliveredItems.ContainsKey($code)) { continue }   # shipped; PASS B marks it dispatched
            $act.Action = 'remove'
            $act.Note   = "closed in SAP with no delivery against it - dropped by the factory (ERPNext still has $erpKg kg)."
            $removals++
            [void]$out.Actions.Add($act); continue
        }

        $newKg = $sapKg[$code]
        if ($erpKg -le 0) {
            $act.Note = 'custom_total_weight is missing or zero, so there is nothing to scale from.'
            [void]$out.Actions.Add($act); continue
        }
        if ([math]::Abs($newKg - $erpKg) -le $Tolerance) { continue }   # already agrees

        $cat  = "$(Get-JsonProp $it 'custom_product_category')"
        $erpQty   = ConvertTo-Number (Get-JsonProp $it 'qty')
        $erpRolls = ConvertTo-Number (Get-JsonProp $it 'custom_rolls')
        $erpBelts = [int](ConvertTo-Number (Get-JsonProp $it 'custom_loose_belts'))
        $rate     = ConvertTo-Number (Get-JsonProp $it 'rate')

        $ratio    = $newKg / $erpKg
        $newQty   = [math]::Round($erpQty * $ratio, 6)
        $newRolls = [math]::Round($erpRolls * $ratio, 0)
        $newBelts = [int][math]::Round($erpBelts * $ratio, 0)

        $note = New-ErpPackingNote -Category $cat -Rolls $newRolls -Belts $newBelts -WeightKg $newKg
        if ($null -eq $note) {
            $act.Note = "item $code is family '$cat' - its packing note cannot be rebuilt here, so the line is left for a human rather than corrected into disagreeing with its own note."
            [void]$out.Actions.Add($act); continue
        }

        $act.Action = 'reduce'
        $act.Fields = @{
            'custom_total_weight' = $newKg
            'qty'                 = $newQty
            'custom_rolls'        = $newRolls
            'custom_loose_belts'  = $newBelts
            # qty x rate is the identity ERPNext itself recomputes; writing the
            # amount to match keeps the two from disagreeing for the instant
            # between the write and the parent's recalculation.
            'amount'              = [math]::Round($newQty * $rate, 2)
            'custom_packing_note' = $note
        }
        $act.Note = ("{0} kg -> {1} kg" -f $erpKg, $newKg)
        [void]$out.Actions.Add($act)
    }

    if ($removals -gt 0 -and $removals -ge $erp.Count) {
        # Every line would go. Either SAP really has lost the lot - which wants
        # a human, not a sync - or something upstream is wrong: a cancelled
        # order closes every row at once and reads exactly like this, which is
        # why the caller skips a cancelled order before reaching here.
        $out.Abort = "all $($erp.Count) line(s) would be removed - refusing to empty the order. Frappe would refuse the last row anyway."
        $out.Actions = New-Object System.Collections.ArrayList
    }
    return $out
}

function ConvertTo-DateOnly {
    param($Value)
    if (-not "$Value".Trim()) { return $null }
    try { return ([datetime]"$Value").ToString('yyyy-MM-dd') } catch { return $null }
}

# --------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------

$exitCode = 0
try {
    $config = Read-JsonConfig -Path $ConfigPath

    # ---- ERPNext ----
    $erp = Get-JsonProp $config 'erpnext'
    if (-not $erp) { throw "config: 'erpnext' section is missing." }
    $script:ErpBaseUrl    = Get-RequiredString $erp 'site'       'erpnext'
    $erpKey               = Get-RequiredString $erp 'api_key'    'erpnext'
    $erpSecret            = Get-RequiredString $erp 'api_secret' 'erpnext'
    $script:ErpAuthHeader = "token ${erpKey}:${erpSecret}"

    # ---- SAP ----
    $sap = Get-JsonProp $config 'sap'
    if (-not $sap) { throw "config: 'sap' section is missing." }
    $sapUrl  = (Get-RequiredString $sap 'url' 'sap').TrimEnd('/')
    $sapUser =  Get-RequiredString $sap 'username' 'sap'
    $sapPass =  Get-RequiredString $sap 'password' 'sap'
    $verifySsl = $true
    $vp = $sap.PSObject.Properties['verify_ssl']
    if ($vp) { $verifySsl = [bool]$vp.Value }
    $script:SapSkipCert = (-not $verifySsl)
    $pageSize = Get-OptionalInt $sap 'page_size' 200
    $sapCo = Get-JsonProp $sap 'company'
    if (-not $sapCo) { throw "config: 'sap.company' is missing." }
    $companyName = Get-RequiredString $sapCo 'name'       'sap.company'
    $companyDb   = Get-RequiredString $sapCo 'company_db' 'sap.company'
    $series          = Get-OptionalString $sap 'series' ''
    $salesPersonCode = Get-OptionalString $sap 'sales_person_code' ''

    # ---- order_sync policy ----
    $os = Get-JsonProp $config 'order_sync'
    if (-not $os) { throw "config: 'order_sync' section is missing." }
    $poGate        = Get-RequiredString $os 'po_status_gate' 'order_sync'
    $fixedCardCode = Get-RequiredString $os 'fixed_card_code' 'order_sync'         # 20416 - the inter-company CardCode, always
    $sendUnitPrice = Get-OptionalBool   $os 'send_line_unit_price' $false          # default OFF - do not send the end-customer rate to the factory
    # SAP is the record for an approved order: the apps refuse to edit one, and
    # the manufacturing team reduce or drop a line there instead. ON by default
    # because an app that cannot edit and does not follow would just be stale.
    $reconcileLines = Get-OptionalBool  $os 'reconcile_lines_from_sap' $true
    # The warehouse each order line names. Empty = let SAP pick its default,
    # which is how every order up to 18 Sep 2026 ended up committing stock to
    # warehouse 01 while the finished goods sat in 07.
    $lineWarehouse = Get-OptionalString $os 'line_warehouse' ''
    $stageSource   = Get-OptionalString $os 'stage_source' 'routing_stages'
    $stampField    = Get-OptionalString $os 'stamp_erpnext_name_in' 'NumAtCard'   # NumAtCard | U_FreeText | none
    $shipDateFrom  = Get-OptionalString $os 'delivery_ship_date_from' 'DocDueDate' # DocDate | DocDueDate
    $deliveryDays  = Get-OptionalInt    $os 'delivery_scan_days' 120
    $statusLabels  = Get-JsonProp $os 'production_status_labels'
    $prodStatuses  = @(Get-JsonProp $os 'production_scan_statuses')
    if (-not $prodStatuses -or $prodStatuses.Count -eq 0) { $prodStatuses = @('boposPlanned', 'boposReleased', 'boposClosed') }

    if ($stampField -notin @('NumAtCard', 'U_FreeText', 'none')) {
        throw "config: order_sync.stamp_erpnext_name_in must be NumAtCard, U_FreeText or none (got '$stampField')."
    }
    if ($shipDateFrom -notin @('DocDate', 'DocDueDate')) {
        throw "config: order_sync.delivery_ship_date_from must be DocDate or DocDueDate (got '$shipDateFrom')."
    }

    # ---- logging ----
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
    $logDir = Join-Path $scriptRoot 'logs'
    $ld = $config.PSObject.Properties['log_dir']
    if ($ld -and "$($ld.Value)".Trim()) {
        $cand = "$($ld.Value)".Trim()
        if ([System.IO.Path]::IsPathRooted($cand)) { $logDir = $cand }
        else { $logDir = Join-Path $scriptRoot ($cand -replace '^[.][\\/]', '') }
    }
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $retentionDays = Get-OptionalInt $config 'log_keep_days' 30
    $script:LogFile = Join-Path $logDir ('sap-order-sync-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    try {
        Get-ChildItem -LiteralPath $logDir -Filter 'sap-order-sync-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    $script:Result.company = $companyName
    Write-Log INFO ("==== run start ==== company='{0}' db='{1}' DryRun={2} Limit={3} gate='{4}' cardCode={5} sendUnitPrice={6} warehouse={11} stageSource={7} stamp={8} shipDate={9} PS={10}" -f `
        $companyName, $companyDb, [bool]$DryRun, $Limit, $poGate, $fixedCardCode, $sendUnitPrice, $stageSource, $stampField, $shipDateFrom, $PSVersionTable.PSVersion, $(if ($lineWarehouse -eq '') { "<SAP default>" } else { $lineWarehouse }))

    # ---- TLS / cert ----
    # The Service Layer answers any POST carrying 'Expect: 100-continue' with an
    # empty-body HTTP 500 in ~10ms, logging nothing. .NET sets this header on
    # POSTs by default, so every Login and every document create fails without
    # it. Must be set before the first request - it is only read when a
    # ServicePoint is created, so changing it later has no effect.
    [System.Net.ServicePointManager]::Expect100Continue = $false
    $script:PrevCertCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    }
    if ($script:SapSkipCert) {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Enable-SapCertBypass -SapHost ([System.Uri]$sapUrl).Host
            Write-Log WARN ("TLS cert validation bypassed for SAP host '{0}' only (verify_ssl=false)." -f ([System.Uri]$sapUrl).Host)
        } else {
            Write-Log WARN "TLS cert validation bypassed for SAP via -SkipCertificateCheck (verify_ssl=false)."
        }
    }
    $useSkip = ($script:SapSkipCert -and $PSVersionTable.PSVersion.Major -ge 6)

    try {
        # ---- 1. ERPNext: the two working sets ----
        # docstatus < 2 (draft OR submitted, never cancelled): neither app submits
        # a Sales Order - approval is a field write, orders stay docstatus 0. The
        # gate is custom_po_status; docstatus only excludes a Frappe cancel.
        # See shared/SAP_ORDER_SYNC.md and shared/DIVERGENCES.md.
        $newFilter = '[["custom_po_status","=","' + $poGate + '"],["' + $script:F_SO + '","in",["",null]],["docstatus","<",2]]'
        $newList   = Get-ErpList -Filters $newFilter -Fields @('name', 'customer', 'transaction_date', 'delivery_date', 'grand_total')
        $newList   = @($newList | Sort-Object { "$($_.name)" })

        $openFilter = '[["' + $script:F_SO + '","is","set"],["' + $script:F_DELIV + '","in",["",null]],["docstatus","<",2]]'
        $openList   = Get-ErpList -Filters $openFilter -Fields @('name', 'customer', $script:F_SO, $script:F_SO_STAT, $script:F_PROD, $script:F_STAGE)
        $openList   = @($openList | Sort-Object { "$($_.name)" })

        $script:Result.inScopeNew = $newList.Count
        Write-Log INFO ("ERPNext: {0} order(s) approved & not yet in SAP; {1} order(s) in SAP & not yet delivered." -f $newList.Count, $openList.Count)

        if ($newList.Count -eq 0 -and $openList.Count -eq 0) {
            Write-Log INFO "nothing to do."
            $script:Result.summary = "SUMMARY | company: $companyName | nothing to do (0 new, 0 open)"
            $script:Result.exitCode = 0
            $exitCode = 0
            # exit (not return): finally blocks still run and write the result JSON;
            # a bare 'return' at script scope would skip the trailing 'exit $exitCode'.
            if ($script:SapSkipCert -and $PSVersionTable.PSVersion.Major -lt 6) {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:PrevCertCallback
            }
            if ($ResultJsonPath) {
                try {
                    $script:Result.finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    $script:Result.elapsedSec = [math]::Round(((Get-Date) - $script:StartedAt).TotalSeconds, 1)
                    ($script:Result | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
                } catch { }
            }
            Write-Log INFO "==== run end ==== nothing to do, exit 0"
            exit 0
        }

        # ---- 2. ONE SAP session ----
        $sess = $null
        try {
            $sess = New-SapWebSession -BaseUrl $sapUrl -Username $sapUser -Password $sapPass `
                -CompanyDb $companyDb -CompanyName $companyName -UseSkipCert $useSkip

            # ---- 2a. the rep -> sales employee map (PASS A only) ----
            # One small GET; SAP has a couple of dozen sales employees. Skipped
            # entirely when there is nothing to create.
            $salesPersonMap = @{}
            if ($newList.Count -gt 0) {
                $salesPersonMap = Get-SapSalesPersonMap -BaseUrl $sapUrl -Session $sess -PageSize $pageSize -UseSkipCert $useSkip
                Write-Log INFO ("SAP: {0} active sales employee(s) can be tagged on an order." -f $salesPersonMap.Count)
            }

            # ---- 2b. prefetch scans for PASS B (only if needed) ----
            $poBySoEntry    = @{}   # SO DocEntry -> ArrayList of production orders
            $posByEntryItem = @{}   # "SO DocEntry|ItemCode" -> ArrayList of production orders
            $dnBySoEntry   = @{}   # SO DocEntry -> delivery note object (earliest by DocDate)
            $dnByEntryItem = @{}   # "SO DocEntry|ItemCode" -> the delivery that carried THAT line
            $sapOrderByDocNum = @{}
            if ($openList.Count -gt 0) {
                # SAP Orders for the open set, resolved by DocNum (need DocEntry to join).
                $docNums = @($openList | ForEach-Object { "$(Get-JsonProp $_ $script:F_SO)".Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
                $chunk = 40
                for ($i = 0; $i -lt $docNums.Count; $i += $chunk) {
                    $slice = $docNums[$i..([math]::Min($i + $chunk - 1, $docNums.Count - 1))]
                    $ors = ($slice | ForEach-Object { "DocNum eq $_" }) -join ' or '
                    # DocumentLines is here for the line reconcile: SAP is the
                    # record for an approved order, so PASS B has to see what
                    # its lines say now, not just the order's status.
                    $rel = "Orders?`$filter=$([uri]::EscapeDataString($ors))&`$select=DocEntry,DocNum,DocumentStatus,Cancelled,NumAtCard,DocumentLines"
                    foreach ($o in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $rel -PageSize $pageSize -UseSkipCert $useSkip -Label "Orders by DocNum")) {
                        $dn = "$(Get-JsonProp $o 'DocNum')"
                        # ArrayList, not Generic.List[object]: @() over a generic list
                        # throws "Argument types do not match" on this PS 5.1 build
                        # (same reason DocumentLines uses ArrayList).
                        if (-not $sapOrderByDocNum.ContainsKey($dn)) { $sapOrderByDocNum[$dn] = New-Object System.Collections.ArrayList }
                        [void]$sapOrderByDocNum[$dn].Add($o)
                    }
                }

                # Open production orders + their SO links and routing stages.
                # Three ways a production order points at its sales order:
                #   - ProductionOrdersSalesOrderLines[].BaseAbsEntry = SO DocEntry
                #   - ProductionOrderOrigin = bopooSalesOrder with
                #     ProductionOrderOriginEntry = SO DocEntry
                #   - ProductionOrderOrigin = bopooManual, same OriginEntry.
                # The third is how this factory actually works: the floor raises
                # standalone orders and types the sales order into the Sales Order
                # field, which links it but leaves the origin Manual. Requiring
                # bopooSalesOrder matched 1 of 31,853 production orders.
                # Other origins (MRP and friends) are NOT accepted - their
                # OriginEntry points at a different document type, so trusting it
                # would attach a production order to an unrelated sales order.
                # Ask only for the production orders that could possibly matter.
                #
                # Filtering on status alone returned every open production order in
                # the company - 32,374 rows over 162 pages, about 50 of the 60
                # seconds a run took - to use the four that belong to the orders in
                # hand. Restricting to the sales orders we actually resolved turns
                # that into a handful of rows.
                #
                # TWO link styles, and SAP records them differently:
                #
                #   - generated by the Procurement Confirmation Wizard: BOTH
                #     ProductionOrderOriginEntry (the DocEntry) and
                #     ProductionOrderOriginNumber (the DocNum) are filled.
                #   - raised standalone with the sales order typed into the
                #     Sales Order field - which is how this floor actually
                #     works: ONLY ProductionOrderOriginNumber is filled.
                #     OriginEntry stays null.
                #
                # This comment used to claim the entry was filled either way. It
                # is not, and so the sync silently ignored every hand-linked
                # production order until 18 September 2026: SAP order 406 had a
                # RELEASED order against its I-14637 line and the line still
                # read Not Started, because the scan below never fetched it.
                #
                # Hence both clauses. The number is resolved back to an entry by
                # Resolve-SoEntryByDocNumAndItem, which refuses when ambiguous -
                # DocNum is not unique here (406 is four different orders).
                $soEntries = @()
                $soDocNums = @()
                foreach ($lst in $sapOrderByDocNum.Values) {
                    foreach ($o in $lst) {
                        $de = "$(Get-JsonProp $o 'DocEntry')".Trim()
                        if ($de -ne '' -and $de -ne '0') { $soEntries += $de }
                        $dnum = "$(Get-JsonProp $o 'DocNum')".Trim()
                        if ($dnum -ne '' -and $dnum -ne '0') { $soDocNums += $dnum }
                    }
                }
                $soEntries = @($soEntries | Select-Object -Unique)
                $soDocNums = @($soDocNums | Select-Object -Unique)

                # Collect EVERY production order per sales order, and per line item,
                # rather than keeping one. A line can need several (a part quantity
                # started now, the rest later) and an order usually needs one per
                # item - the status they roll up to is decided at write time by
                # Select-LeastAdvancedPo.
                $posByEntryItem = @{}   # "<SO DocEntry>|<ItemCode>" -> ArrayList of POs

                $stFilter = ($prodStatuses | ForEach-Object { "ProductionOrderStatus eq '$_'" }) -join ' or '
                $poSelect = 'DocumentNumber,AbsoluteEntry,ItemNo,ProductionOrderStatus,ProductionOrderOrigin,ProductionOrderOriginEntry,ProductionOrderOriginNumber,ProductionOrdersSalesOrderLines,ProductionOrdersStages'
                $poRows = New-Object System.Collections.ArrayList
                # One clause per sales order, by entry AND by number. Matching on
                # the number over-fetches - other orders share a DocNum - but the
                # extras are discarded when the item fails to tie them back.
                $poClauses = @()
                foreach ($e in $soEntries) { $poClauses += "ProductionOrderOriginEntry eq $e" }
                foreach ($n in $soDocNums) { $poClauses += "ProductionOrderOriginNumber eq $n" }
                # Chunked: the filter goes in the URL, and one clause per sales
                # order would eventually outgrow what the Service Layer accepts.
                $poChunk = 20
                for ($i = 0; $i -lt $poClauses.Count; $i += $poChunk) {
                    $slice = $poClauses[$i..([math]::Min($i + $poChunk - 1, $poClauses.Count - 1))]
                    $origins = $slice -join ' or '
                    $f = "($stFilter) and ($origins)"
                    $poRel = "ProductionOrders?`$filter=$([uri]::EscapeDataString($f))&`$select=$poSelect&`$orderby=AbsoluteEntry"
                    foreach ($row in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $poRel -PageSize $pageSize -UseSkipCert $useSkip -Label "ProductionOrders for $($slice.Count) link clause(s)")) {
                        [void]$poRows.Add($row)
                    }
                }
                # The same production order can come back from both clauses.
                $seenPo = @{}
                $uniqPo = New-Object System.Collections.ArrayList
                foreach ($row in $poRows) {
                    $ae = "$(Get-JsonProp $row 'AbsoluteEntry')".Trim()
                    if ($ae -ne '' -and $seenPo.ContainsKey($ae)) { continue }
                    if ($ae -ne '') { $seenPo[$ae] = $true }
                    [void]$uniqPo.Add($row)
                }
                $poRows = $uniqPo

                $poByNumber = 0
                foreach ($po in $poRows) {
                    $item = "$(Get-JsonProp $po 'ItemNo')".Trim()
                    $seen = @{}
                    foreach ($sol in @(Get-JsonProp $po 'ProductionOrdersSalesOrderLines')) {
                        $be = "$(Get-JsonProp $sol 'BaseAbsEntry')".Trim()
                        if ($be -eq '') { continue }
                        Add-PoToMap $poBySoEntry $be $po
                        if ($item) { Add-PoToMap $posByEntryItem "$be|$item" $po }
                        $seen[$be] = $true
                    }
                    $origin = "$(Get-JsonProp $po 'ProductionOrderOrigin')"
                    if ($origin -eq 'bopooSalesOrder' -or $origin -eq 'bopooManual') {
                        $oe = "$(Get-JsonProp $po 'ProductionOrderOriginEntry')".Trim()
                        if ($oe -ne '' -and $oe -ne '0') {
                            if (-not $seen.ContainsKey($oe)) {
                                Add-PoToMap $poBySoEntry $oe $po
                                if ($item) { Add-PoToMap $posByEntryItem "$oe|$item" $po }
                            }
                        }
                        else {
                            # Linked by hand: the number is filled, the entry is not.
                            $onum = "$(Get-JsonProp $po 'ProductionOrderOriginNumber')".Trim()
                            if ($onum -ne '' -and $onum -ne '0' -and $sapOrderByDocNum.ContainsKey($onum)) {
                                $res = Resolve-SoEntryByDocNumAndItem -Candidates $sapOrderByDocNum[$onum] -ItemCode $item
                                if ($res.Entry -ne '' -and -not $seen.ContainsKey($res.Entry)) {
                                    Add-PoToMap $poBySoEntry $res.Entry $po
                                    Add-PoToMap $posByEntryItem "$($res.Entry)|$item" $po
                                    $poByNumber++
                                }
                                elseif ($res.Entry -eq '') {
                                    # Never guess. A wrongly attached production
                                    # order reports someone else's order as being
                                    # made - see Resolve-SoEntryByDocNumAndItem.
                                    Write-Log WARN ("production order {0} ({1}) names sales order {2} but {3} - not attached to any order." -f `
                                        "$(Get-JsonProp $po 'DocumentNumber')", $item, $onum, $res.Reason)
                                }
                            }
                        }
                    }
                }
                if ($poByNumber -gt 0) {
                    Write-Log INFO ("SAP prefetch: {0} production order(s) attached by sales order NUMBER (typed in by hand, no DocEntry link)." -f $poByNumber)
                }

                # Recent deliveries + their base-document links.
                $cutoff = (Get-Date).AddDays(-1 * [math]::Abs($deliveryDays)).ToString('yyyy-MM-dd')
                $dnRel = "DeliveryNotes?`$filter=DocDate ge $cutoff&`$select=DocEntry,DocNum,DocDate,DocDueDate,DocumentLines&`$orderby=DocDate"
                $dnRel = $dnRel -replace ' ', '%20'
                foreach ($dn in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $dnRel -PageSize $pageSize -UseSkipCert $useSkip -Label "recent DeliveryNotes")) {
                    foreach ($dl in @(Get-JsonProp $dn 'DocumentLines')) {
                        if ([int](ConvertTo-Number (Get-JsonProp $dl 'BaseType')) -ne $SAP_BASETYPE_SALESORDER) { continue }
                        $be = "$(Get-JsonProp $dl 'BaseEntry')".Trim()
                        if ($be -eq '') { continue }
                        if (-not $dnBySoEntry.ContainsKey($be)) { $dnBySoEntry[$be] = $dn }   # earliest by DocDate - orderby asc
                        # Per LINE as well as per order. A delivery need not carry
                        # the whole order - dropping a row from it is how the floor
                        # ships what is ready and leaves the rest open. Recording
                        # only the order-level delivery would mark every line
                        # Dispatched the moment ANY line shipped.
                        $di = "$(Get-JsonProp $dl 'ItemCode')".Trim()
                        if ($di -ne '' -and -not $dnByEntryItem.ContainsKey("$be|$di")) {
                            $dnByEntryItem["$be|$di"] = $dn
                        }
                    }
                }
                Write-Log INFO ("SAP prefetch: {0} SAP order(s) resolved, {1} PO<-SO link(s), {2} delivery<-SO link(s)." -f `
                    ($sapOrderByDocNum.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum, $poBySoEntry.Count, $dnBySoEntry.Count)
            }

            $nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

            # =================== PASS A - create new SAP orders ===================
            $doneA = 0
            foreach ($row in $newList) {
                if ($Limit -gt 0 -and $doneA -ge $Limit) { Write-Log WARN ("PASS A -Limit {0} reached; {1} approved order(s) left for the next run." -f $Limit, ($newList.Count - $doneA)); break }
                $name = "$($row.name)"
                $doneA++
                try {
                    # (1) fresh re-read - must still be un-synced
                    $doc = Get-ErpSalesOrder -Name $name
                    $already = "$(Get-JsonProp $doc $script:F_SO)".Trim()
                    if ($already -ne '') { Write-Log WARN ("PASS A {0}: {1} is already '{2}' - skipping (no double create)." -f $name, $script:F_SO, $already); continue }
                    if ([int](ConvertTo-Number (Get-JsonProp $doc 'docstatus')) -eq 2) { Write-Log WARN ("PASS A {0}: order is cancelled (docstatus 2) - skipping." -f $name); continue }
                    if ("$(Get-JsonProp $doc 'custom_po_status')" -ne $poGate) { Write-Log WARN ("PASS A {0}: custom_po_status is no longer '{1}' - skipping." -f $name, $poGate); continue }

                    # CardCode is ALWAYS the fixed inter-company code (20416). No
                    # end-customer lookup - the factory must not learn who the
                    # goods are for. custom_bp_code is not read here.
                    $cardCode = $fixedCardCode

                    # lines
                    $items = @(Get-JsonProp $doc 'items')
                    if ($items.Count -eq 0) {
                        $msg = "Sales Order has no item rows."
                        Write-Log ERROR ("PASS A {0}: {1}" -f $name, $msg)
                        if (-not $DryRun) { Update-ErpSalesOrder -Name $name -Fields @{ $script:F_ERR = $msg; $script:F_SYNCED = $nowStr } }
                        $script:Result.createFailed++; $script:Result.failures++
                        continue
                    }
                    # ArrayList, not Generic.List[object]: on this PS 5.1 build @() over a
                    # generic list holding hashtables throws "Argument types do not match".
                    $lines = New-Object System.Collections.ArrayList
                    $lineErr = $null
                    $idx = 0
                    foreach ($it in $items) {
                        $built = New-SapOrderLine -Item $it -SendUnitPrice $sendUnitPrice -OrderName $name -Index $idx -Warehouse $lineWarehouse
                        if ($built.Error) { $lineErr = $built.Error; break }
                        [void]$lines.Add($built.Line)
                        $idx++
                    }
                    if ($lineErr) {
                        Write-Log ERROR ("PASS A {0}: {1}" -f $name, $lineErr)
                        if (-not $DryRun) { Update-ErpSalesOrder -Name $name -Fields @{ $script:F_ERR = $lineErr; $script:F_SYNCED = $nowStr } }
                        $script:Result.createFailed++; $script:Result.failures++
                        continue
                    }

                    # (2) adopt an already-created SAP order if the name is stamped there
                    $adopt = $null
                    if ($stampField -ne 'none') {
                        $q = "$stampField eq '$($name -replace "'", "''")'"
                        $rel = "Orders?`$filter=$([uri]::EscapeDataString($q))&`$select=DocEntry,DocNum,DocumentStatus,Cancelled"
                        $hits = @(Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $rel -PageSize $pageSize -UseSkipCert $useSkip -Label "Orders by $stampField")
                        # Only a hit that carries a real DocNum is an adoption. A
                        # row with a blank DocNum is not a SAP order and must never
                        # be written back as custom_sap_sales_order.
                        foreach ($h in $hits) {
                            if ("$(Get-JsonProp $h 'DocNum')".Trim() -ne '') { $adopt = $h; break }
                        }
                    }

                    $dueDate = ConvertTo-DateOnly (Get-JsonProp $doc 'delivery_date')
                    if (-not $dueDate) { $dueDate = ConvertTo-DateOnly (Get-JsonProp $doc 'transaction_date') }
                    if (-not $dueDate) { $dueDate = (Get-Date).ToString('yyyy-MM-dd') }
                    # Payload carries ONLY: fixed CardCode, dates, item lines,
                    # the Manna rep as SalesPersonCode, and the opaque ERPNext
                    # order name in NumAtCard. No Comments, no address, no
                    # territory, no contact - nothing that identifies the end
                    # customer. The rep is one of OUR people, not the buyer, so
                    # naming them tells the factory whose order to chase and
                    # gives away nothing about who it is for.
                    $payload = [ordered]@{
                        CardCode      = $cardCode
                        DocDate       = (Get-Date).ToString('yyyy-MM-dd')
                        DocDueDate    = $dueDate
                        DocumentLines = $lines
                    }
                    if ($series -ne '') { $payload.Series = [int]$series }

                    $sp = Resolve-SapSalesPersonCode -RepName "$(Get-JsonProp $doc 'custom_sales_person')" `
                            -Map $salesPersonMap -Fallback $salesPersonCode
                    if ($sp.Warning) {
                        Write-Log WARN ("PASS A {0}: {1}." -f $name, $sp.Warning)
                        $script:Result.repUnmatched++
                    }
                    if ($null -ne $sp.Code) { $payload.SalesPersonCode = [int]$sp.Code }

                    if     ($stampField -eq 'NumAtCard') { $payload.NumAtCard  = $name }
                    elseif ($stampField -eq 'U_FreeText') { $payload.U_FreeText = $name }

                    if ($adopt) {
                        $docNum = "$(Get-JsonProp $adopt 'DocNum')"
                        Write-Log WARN ("PASS A {0}: SAP already has an Order with {1} = '{2}' (DocNum {3}) - ADOPTING it, not creating another." -f $name, $stampField, $name, $docNum)
                        if (-not $DryRun) {
                            Update-ErpSalesOrder -Name $name -Fields @{
                                $script:F_SO      = $docNum
                                $script:F_SO_STAT = (Resolve-SoStatus $adopt)
                                $script:F_SYNCED  = $nowStr
                                $script:F_ERR     = ''
                            }
                        }
                        $script:Result.adopted++; $script:Result.changed++
                        continue
                    }

                    if ($DryRun) {
                        Write-Log INFO ("PASS A {0}: WOULD POST /Orders:`n{1}" -f $name, ($payload | ConvertTo-Json -Depth 8))
                        Write-Log INFO ("PASS A {0}: WOULD then write {1}=<DocNum>, {2}=<status>, {3}, clear {4}." -f $name, $script:F_SO, $script:F_SO_STAT, $script:F_SYNCED, $script:F_ERR)
                        continue
                    }

                    # (3) create
                    $created = New-SapSalesOrder -BaseUrl $sapUrl -Session $sess -Payload $payload -UseSkipCert $useSkip
                    $docNum  = "$(Get-JsonProp $created 'DocNum')"
                    $docEntry = "$(Get-JsonProp $created 'DocEntry')"
                    $spWord = if ($null -eq $sp.Code) { 'no sales employee' } else { "sales employee $($sp.Code)" }
                    Write-Log INFO ("PASS A {0}: SAP Order created - DocNum {1} (DocEntry {2}), status {3}, {4}." -f $name, $docNum, $docEntry, (Resolve-SoStatus $created), $spWord)

                    # (4) write back IMMEDIATELY
                    try {
                        Update-ErpSalesOrder -Name $name -Fields @{
                            $script:F_SO      = $docNum
                            $script:F_SO_STAT = (Resolve-SoStatus $created)
                            $script:F_SYNCED  = $nowStr
                            $script:F_ERR     = ''
                        }
                        $script:Result.created++; $script:Result.changed++
                    } catch {
                        # SAP order EXISTS but ERPNext did not record it. The NumAtCard/U_FreeText
                        # stamp lets the next run adopt it. Loud, and a hard failure.
                        Write-Log ERROR ("PASS A {0}: SAP Order DocNum {1} WAS CREATED but the ERPNext write-back FAILED: {2}  ==> reconcile by hand or let the next run adopt via {3}." -f $name, $docNum, $_, $stampField)
                        $script:Result.writeErrors++; $script:Result.failures++
                    }
                } catch {
                    $emsg = "$_"
                    Write-Log ERROR ("PASS A {0}: FAILED - {1}" -f $name, $emsg)
                    try { if (-not $DryRun) { Update-ErpSalesOrder -Name $name -Fields @{ $script:F_ERR = ($emsg.Substring(0, [math]::Min(500, $emsg.Length))); $script:F_SYNCED = $nowStr } } } catch { }
                    $script:Result.createFailed++; $script:Result.failures++
                }
            }

            # =================== PASS B - pull PO / stage / delivery ===================
            $doneB = 0
            foreach ($row in $openList) {
                if ($Limit -gt 0 -and $doneB -ge $Limit) { Write-Log WARN ("PASS B -Limit {0} reached; {1} open order(s) left for the next run." -f $Limit, ($openList.Count - $doneB)); break }
                $name  = "$($row.name)"
                $soNum = "$(Get-JsonProp $row $script:F_SO)".Trim()
                $doneB++
                try {
                    $fields = @{ $script:F_SYNCED = $nowStr }

                    # resolve the SAP Order (DocNum -> DocEntry, refresh status)
                    $sapOrder = $null
                    if ($sapOrderByDocNum.ContainsKey($soNum)) {
                        $cands = $sapOrderByDocNum[$soNum]   # ArrayList - do NOT wrap in @() on this build
                        if ($cands.Count -eq 1) {
                            $sapOrder = $cands[0]
                        }
                        else {
                            # DocNum is not unique across the DB's Sales Order series;
                            # NumAtCard (the ERPNext order name) is the tie-breaker.
                            foreach ($c in $cands) {
                                if ("$(Get-JsonProp $c 'NumAtCard')" -eq $name) { $sapOrder = $c; break }
                            }
                            if (-not $sapOrder) { Write-Log WARN ("PASS B {0}: DocNum {1} matches {2} SAP orders and none carry NumAtCard='{0}' - status/links skipped this pass." -f $name, $soNum, $cands.Count) }
                        }
                    } else {
                        Write-Log WARN ("PASS B {0}: SAP Order DocNum {1} not found - status/links skipped this pass." -f $name, $soNum)
                    }

                    $soEntry = $null
                    if ($sapOrder) {
                        $soEntry = "$(Get-JsonProp $sapOrder 'DocEntry')".Trim()
                        $fields[$script:F_SO_STAT] = (Resolve-SoStatus $sapOrder)
                    }

                    # production order + current stage (order roll-up)
                    if ($soEntry -and $poBySoEntry.ContainsKey($soEntry)) {
                        $po = Select-LeastAdvancedPo $poBySoEntry[$soEntry]
                        if ($po) {
                            $fields[$script:F_PROD]  = "$(Get-JsonProp $po 'DocumentNumber')"
                            $fields[$script:F_STAGE] = (Resolve-CurrentStage -Po $po -Labels $statusLabels -StageSource $stageSource)
                            $script:Result.productionMatched++
                            if ("$($fields[$script:F_STAGE])".Trim()) { $script:Result.stagesWritten++ }
                        }
                    }

                    # Delivery + ship date at ORDER level - and only once the WHOLE
                    # order has gone.
                    #
                    # This field is what takes an order out of PASS B: the scan
                    # reads orders where it is still empty. Writing it for a
                    # partial delivery retires an order that still owes the
                    # customer a line, and nothing would ever poll it again -
                    # the remaining line would freeze at whatever stage it had
                    # when the first lorry left. Seen on SAP order 381, where
                    # three lines shipped on DN 1 and the fourth stayed open.
                    #
                    # A line that HAS gone still says so: the per-line delivery
                    # written below is not gated on this.
                    if ($soEntry -and $dnBySoEntry.ContainsKey($soEntry) -and $sapOrder) {
                        $soStatus = "$(Get-JsonProp $sapOrder 'DocumentStatus')"
                        if ($soStatus -eq 'bost_Close') {
                            $dn = $dnBySoEntry[$soEntry]
                            $fields[$script:F_DELIV]    = "$(Get-JsonProp $dn 'DocNum')"
                            $shipRaw = Get-JsonProp $dn $shipDateFrom
                            $ship = ConvertTo-DateOnly $shipRaw
                            if ($ship) { $fields[$script:F_DELIV_DT] = $ship }
                            $script:Result.deliveriesWritten++
                        } else {
                            Write-Log INFO ("PASS B {0}: delivered in part - SAP order still {1}, so the order-level delivery is left unset and it stays in scope." -f $name, $soStatus)
                        }
                    }

                    $fields[$script:F_ERR] = ''   # clean pass clears a stale error

                    # Per-line production status. SAP links a production order to the
                    # sales ORDER, not to a line, so the join is the item code. An
                    # item appearing on two lines of one order would be ambiguous;
                    # both lines then get the same status, which is the honest answer
                    # since SAP cannot say which line the production covers.
                    $lineUpdates = New-Object System.Collections.ArrayList
                    if ($soEntry) {
                        $full = Get-ErpSalesOrder -Name $name

                        # ---- make ERPNext's lines match SAP's ----
                        #
                        # Runs BEFORE the per-line status below, and re-reads
                        # the order when it changes anything: a row the
                        # reconcile deletes must not then be written to.
                        # A cancelled SAP order is not a line-level change and
                        # must not be reconciled. Cancelling closes every row,
                        # and a closed row with no delivery is how the factory
                        # says "dropped" - so reconciling a cancelled order
                        # reads as "every line dropped" and tries to empty it.
                        # Seen on SAL-ORD-2026-00138 / DocEntry 2884, which the
                        # all-gone guard caught. The order's own status carries
                        # the cancellation; the lines stay as the record of what
                        # was ordered.
                        $sapCancelled = $sapOrder -and ((Resolve-SoStatus $sapOrder) -eq 'bost_Cancelled')
                        if ($reconcileLines -and $sapOrder -and $sapCancelled) {
                            Write-Log INFO ("PASS B {0}: SAP order is cancelled - lines left as they are." -f $name)
                        }
                        elseif ($reconcileLines -and $sapOrder) {
                            # Which items a delivery actually carried for THIS
                            # order. A SAP line closes both when it ships and
                            # when the factory drops it, and nothing on the
                            # line itself tells the two apart - see
                            # Get-ErpLineCorrections.
                            $delivered = @{}
                            foreach ($dk in $dnByEntryItem.Keys) {
                                $bits = "$dk".Split('|', 2)
                                if ($bits.Count -eq 2 -and $bits[0] -eq $soEntry) { $delivered[$bits[1]] = $true }
                            }

                            $plan = Get-ErpLineCorrections `
                                -SapLines @(Get-JsonProp $sapOrder 'DocumentLines') `
                                -ErpItems @(Get-JsonProp $full 'items') `
                                -DeliveredItems $delivered

                            if ($plan.Abort) {
                                Write-Log WARN ("PASS B {0}: lines not reconciled - {1}" -f $name, $plan.Abort)
                            }
                            $touched = 0
                            foreach ($a in $plan.Actions) {
                                switch ($a.Action) {
                                    'skip' {
                                        Write-Log WARN ("PASS B {0}: line {1} left alone - {2}" -f $name, $a.ItemCode, $a.Note)
                                    }
                                    'remove' {
                                        if ($DryRun) {
                                            Write-Log INFO ("PASS B {0}: WOULD REMOVE line {1} - {2}" -f $name, $a.ItemCode, $a.Note)
                                        } else {
                                            try {
                                                Remove-ErpOrderLine -RowName $a.RowName
                                                Write-Log INFO ("PASS B {0}: removed line {1} - {2}" -f $name, $a.ItemCode, $a.Note)
                                                $script:Result.linesRemoved++
                                                $touched++
                                            } catch {
                                                Write-Log WARN ("PASS B {0}: could not remove line {1} - {2}" -f $name, $a.ItemCode, "$_")
                                                $script:Result.failures++
                                            }
                                        }
                                    }
                                    'reduce' {
                                        if ($DryRun) {
                                            Write-Log INFO ("PASS B {0}: WOULD CORRECT line {1} ({2}) to {3}" -f `
                                                $name, $a.ItemCode, $a.Note, (($a.Fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
                                        } else {
                                            try {
                                                Update-ErpOrderLine -RowName $a.RowName -Fields $a.Fields
                                                Write-Log INFO ("PASS B {0}: corrected line {1} - {2}" -f $name, $a.ItemCode, $a.Note)
                                                $script:Result.linesCorrected++
                                                $touched++
                                            } catch {
                                                Write-Log WARN ("PASS B {0}: could not correct line {1} - {2}" -f $name, $a.ItemCode, "$_")
                                                $script:Result.failures++
                                            }
                                        }
                                    }
                                }
                            }
                            if ($touched -gt 0) { $full = Get-ErpSalesOrder -Name $name }
                        }

                        foreach ($row in @(Get-JsonProp $full 'items')) {
                            $ic = "$(Get-JsonProp $row 'item_code')".Trim()
                            $rn = "$(Get-JsonProp $row 'name')".Trim()
                            if (-not $ic -or -not $rn) { continue }
                            # Not gated on there being a production order: a line
                            # can be delivered from stock without one, and would
                            # otherwise never be told it had shipped.
                            $key = "$soEntry|$ic"
                            $lf = @{}

                            $lpo = $null
                            if ($posByEntryItem.ContainsKey($key)) {
                                $lpo = Select-LeastAdvancedPo $posByEntryItem[$key]
                            }
                            if ($lpo) {
                                $lf['custom_sap_production_order'] = "$(Get-JsonProp $lpo 'DocumentNumber')"
                                $lf['custom_sap_production_stage'] = (Resolve-CurrentStage -Po $lpo -Labels $statusLabels -StageSource $stageSource)
                            }
                            else {
                                # NO LIVE PRODUCTION ORDER - and the line is only
                                # told so if it was previously told otherwise.
                                #
                                # Cancelling a released production order is the
                                # case this exists for. Select-LeastAdvancedPo
                                # skips cancelled orders, so the line has nothing
                                # covering it and nothing is being made for it.
                                # Until 18 Sep 2026 the sync simply wrote nothing
                                # here, so the last stage it had written stood for
                                # ever: a line whose production order was cancelled
                                # after release read "In Production" indefinitely,
                                # with no press anywhere near it.
                                #
                                # Clearing both fields puts the line back to Not
                                # Started, which is where a line with no production
                                # order belongs - see `line_stage_to_status` in
                                # shared/fixtures/sap_order_state.json.
                                $hadPo    = "$(Get-JsonProp $row 'custom_sap_production_order')".Trim()
                                $hadStage = "$(Get-JsonProp $row 'custom_sap_production_stage')".Trim()
                                if (($hadPo -and $hadPo -ne 'null') -or ($hadStage -and $hadStage -ne 'null')) {
                                    $lf['custom_sap_production_order'] = ''
                                    $lf['custom_sap_production_stage'] = ''
                                    Write-Log INFO ("PASS B {0}: line {1} has no live production order (was PO '{2}' / '{3}') - back to Not Started." -f `
                                        $name, $ic, $hadPo, $hadStage)
                                    $script:Result.stagesCleared++
                                }
                            }

                            # The delivery that carried THIS line, if any. A line
                            # left off a partial delivery keeps these blank and so
                            # never reads Dispatched, while its neighbours do.
                            if ($dnByEntryItem.ContainsKey($key)) {
                                $ldn = $dnByEntryItem[$key]
                                $lf['custom_sap_delivery_order'] = "$(Get-JsonProp $ldn 'DocNum')"
                                $lship = ConvertTo-DateOnly (Get-JsonProp $ldn $shipDateFrom)
                                if ($lship) { $lf['custom_sap_delivery_date'] = $lship }
                            }

                            if ($lf.Count -eq 0) { continue }
                            [void]$lineUpdates.Add([pscustomobject]@{
                                RowName  = $rn
                                ItemCode = $ic
                                Fields   = $lf
                            })
                        }
                    }

                    if ($DryRun) {
                        Write-Log INFO ("PASS B {0}: WOULD write {1}" -f $name, (($fields.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
                        foreach ($lu in $lineUpdates) {
                            Write-Log INFO ("PASS B {0}:   line {1} WOULD get {2}" -f $name, $lu.ItemCode, (($lu.Fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
                        }
                    } else {
                        Update-ErpSalesOrder -Name $name -Fields $fields
                        Write-Log INFO ("PASS B {0}: wrote {1}" -f $name, (($fields.Keys | Where-Object { $_ -ne $script:F_SYNCED } | Sort-Object) -join ', '))
                        foreach ($lu in $lineUpdates) {
                            try {
                                Update-ErpOrderLine -RowName $lu.RowName -Fields $lu.Fields
                                $script:Result.linesWritten++
                            } catch {
                                # A line that will not take its status must not fail the
                                # whole order - the header roll-up is already written.
                                Write-Log WARN ("PASS B {0}: line {1} write failed - {2}" -f $name, $lu.ItemCode, "$_")
                            }
                        }
                        if ($lineUpdates.Count -gt 0) {
                            Write-Log INFO ("PASS B {0}: wrote per-line status to {1} line(s)" -f $name, $lineUpdates.Count)
                        }
                    }
                    $script:Result.openPolled++
                    $script:Result.changed++
                } catch {
                    $emsg = "$_"
                    Write-Log ERROR ("PASS B {0}: FAILED - {1}" -f $name, $emsg)
                    try { if (-not $DryRun) { Update-ErpSalesOrder -Name $name -Fields @{ $script:F_ERR = ($emsg.Substring(0, [math]::Min(500, $emsg.Length))); $script:F_SYNCED = $nowStr } } } catch { }
                    $script:Result.failures++
                }
            }
        }
        finally {
            Invoke-SapLogout -BaseUrl $sapUrl -Session $sess -UseSkipCert $useSkip
        }

        # ---- summary ----
        $r = $script:Result
        $modeWord = if ($DryRun) { 'DRY-RUN' } else { 'APPLIED' }
        $summary = ("SUMMARY | {0} | company: {1} | new in scope: {2} | created: {3} | adopted: {4} | create-failed: {5} | rep unmatched: {16} | open polled: {6} | production matched: {7} | stages: {8} | lines: {9} | corrected: {13} | removed: {14} | stages cleared: {15} | deliveries: {10} | write-back errors: {11} | failures: {12}" -f `
            $modeWord, $companyName, $r.inScopeNew, $r.created, $r.adopted, $r.createFailed, $r.openPolled, $r.productionMatched, $r.stagesWritten, $r.linesWritten, $r.deliveriesWritten, $r.writeErrors, $r.failures, $r.linesCorrected, $r.linesRemoved, $r.stagesCleared, $r.repUnmatched)
        Write-Log INFO $summary
        $script:Result.summary = $summary

        if ($r.failures -gt 0) { $exitCode = 1; Write-Log ERROR ("run finished WITH {0} failure(s)." -f $r.failures) }
        else { Write-Log INFO "run finished clean." }
    }
    finally {
        if ($script:SapSkipCert -and $PSVersionTable.PSVersion.Major -lt 6) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:PrevCertCallback
        }
    }
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    $script:Result.error = "$msg"
    if (-not $script:Result.summary) { $script:Result.summary = "FATAL: $msg" }
    try { Write-Log ERROR ("FATAL: {0}" -f $msg) } catch { Write-Host "FATAL: $msg" -ForegroundColor Red }
    try { Write-Log ERROR ("at: {0}" -f $_.ScriptStackTrace) } catch { }
}
finally {
    try { Write-Log INFO ("==== run end ==== elapsed {0:n1}s exit {1}" -f ((Get-Date) - $script:StartedAt).TotalSeconds, $exitCode) } catch { }
    if ($ResultJsonPath) {
        try {
            $script:Result.exitCode   = $exitCode
            $script:Result.finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            $script:Result.elapsedSec = [math]::Round(((Get-Date) - $script:StartedAt).TotalSeconds, 1)
            ($script:Result | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
        } catch {
            try { Write-Log WARN ("could not write ResultJsonPath '{0}': {1}" -f $ResultJsonPath, $_.Exception.Message) } catch { }
        }
    }
}

exit $exitCode
