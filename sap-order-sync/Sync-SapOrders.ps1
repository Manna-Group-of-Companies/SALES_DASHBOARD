<#
.SYNOPSIS
  ERPNext <-> SAP Business One (HITECH_PRETREADS_LIVE) order sync - SAP side.

.DESCRIPTION
  One ERPNext read, ONE Hi-Tech Service Layer login (also when only PASS C
  has work, to check Hi-Tech's own order; and, only when PASS C has a queued
  order, one Manna Treads login after it - never two seats at once), then
  per order:

  Hi-Tech Pretreads is the FACTORY. It manufactures and bills Manna Treads and
  has NO visibility of the end customer. The SAP Sales Order created here carries
  ONLY: the fixed inter-company CardCode (10118 "Manna Treads Private
  Limited- SHOP"; 20416, the Gujarat company, until 26 Sep 2026), dates, item codes, quantities, and the opaque ERPNext order
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
         CardCode      <- order_sync.fixed_card_code  (10118, always - no lookup)
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
                          CardCode 10118's own Price List 01, which does not
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

  PASS B - orders already in SAP, not yet fully invoiced
    In scope:  custom_sap_sales_order set  AND  custom_sap_invoice empty
               AND docstatus < 2
    Using one scan of recent DeliveryNotes and one of recent A/R Invoices:
      custom_sap_sales_order_status <- refreshed SAP status verbatim
      lines                         <- reconciled to SAP (a line the factory
                                       reduced or dropped there is reduced or
                                       removed here)
      custom_sap_invoice (LINE)     <- Invoices.DocNum of the invoice that
                                       carried THIS line. An invoice line is
                                       based either on the sales order
                                       (BaseType 17) or on a delivery
                                       (BaseType 15), which is then followed
                                       back to its own sales-order base.
      custom_sap_invoice_date (LINE)<- that invoice's DocDate
      custom_sap_invoice (ORDER)    <- written only once EVERY line is invoiced,
                                       because it is what takes the order out
                                       of this pass. It names the invoice that
                                       completed the order.
    custom_sap_synced_at is stamped on EVERY pass, changed or not.
    custom_sap_sync_error is cleared on any clean pass.

    The delivery scan does not set any status. It stays because the line
    reconcile needs it: a SAP line closes both when it ships and when the
    factory drops it, and only "was this item delivered or invoiced?" tells
    the two apart.

    Only a delivery whose CancelStatus is csNo counts (26 Sep 2026). A
    cancelled delivery and its reversal document used to count as shipped.

    Stage two (26 Sep 2026) - per LINE, what Hi-Tech actually sent:
      custom_hitech_delivered_kg    <- kilos on live deliveries drawn from
                                       this line (BaseType 17 -> BaseLine)
      custom_hitech_invoiced_kg     <- kilos on live invoice lines drawn
                                       STRAIGHT from this line (BaseType 17)
      custom_hitech_delivery_refs   <- "DN 4 (18-09-2026), DN 7 (...)"
    Written only when a value changes. The SAP line is matched to the ERPNext
    row by item code, as everywhere else here. The kilos are written BEFORE
    the order header; if one fails, the header holds back the SAP status and
    the order-level invoice (which would retire it) until the next run.
    Never written when the Hi-Tech SO's NumAtCard names ANOTHER ERPNext order
    (a Desk copy, or a hand-typed DocNum): those kilos are that order's.

  PASS B (follow) - invoiced in full, still open at Hi-Tech (26 Sep 2026)
    In scope:  custom_company = "Manna Treads"  AND  custom_sap_sales_order set
               AND custom_sap_invoice SET  AND  custom_mt_sales_order empty
               AND docstatus < 2
               AND custom_sap_sales_order_status not in (bost_Close, bost_Cancelled)
    An order PASS B has retired while Hi-Tech's SO is still open (short-
    delivered and invoiced before Hi-Tech closed it). Only its SAP status and
    the three Hi-Tech kilo fields are refreshed - kilos first, and the status
    held back a run if one fails - until Hi-Tech closes it and PASS C can
    bill it. No line reconcile, no invoice linking.

  PASS C - Manna Treads sales orders (stage two, 26 Sep 2026)
    In scope:  custom_mt_so_requested = 1  AND  custom_mt_sales_order empty
               AND custom_mt_sync_error EMPTY (the fixture's 'queued')
               AND custom_sap_sales_order set  AND  custom_po_status = "<gate>"
               AND docstatus < 2
    The accountant approves a finished Hi-Tech order on the dashboard
    (manna_mt_so_request). This pass re-creates it in MANNA_TREADS_LIVE as a
    Sales Order to the END customer (Customer.custom_bp_code), billing only
    what Hi-Tech delivered, at the approved rate net of GST - the rule is
    shared/fixtures/manna_treads_reorder.json, Get-MtReorderPlan here.
    Its own session, logged in only when an order is queued, inside a named
    mutex so two runs cannot both post. The NumAtCard lookup comes FIRST:
    one live order is adopted whatever else is true. Then it refuses what
    it must not create - asked for by someone not in manna_treads.approvers,
    another ERPNext order on the same Hi-Tech SO, an item on two lines,
    Hi-Tech's own order (read by the Hi-Tech session this run) not backing
    the recorded kilos (not closed there, older than the scans, an item on
    two Hi-Tech lines or on a line this order lacks, kilos changed since
    recorded), Hi-Tech not finished, no customer code, a line with no
    price, part invoiced direct on a delivered order, an item outside
    manna_treads.item_allowlist (by default the ten SYNC TEST items) or
    named differently in Manna Treads SAP, a customer missing, inactive,
    named differently or billed outside Kerala, SAP refusing the POST. A
    refusal is written on the order (custom_mt_sync_error,
    custom_mt_synced_at) and is NOT a run failure; the order waits for the
    accountant's Try again. A transient failure writes nothing on the
    order, leaves it queued, and fails the run. Writes custom_mt_sales_order
    (DocNum), custom_mt_sales_order_entry (DocEntry), custom_mt_synced_at,
    and clears custom_mt_sync_error on success. Every line and the header
    carry DiscountPercent 0.

  NO PRODUCTION ORDERS. Decided 24 Sep 2026: under MRP one production order
  pools the demand of many sales orders and SAP does not record which order it
  is for, so production-order linking is out of the initial release. See
  shared/fixtures/sap_order_state.json.

  NEVER written here: custom_production_status (the app derives it), and the
  old custom_sap_production_* / custom_sap_delivery_* fields, which still exist
  in ERPNext and are no longer read by either app.

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
    linesWritten      = 0
    linesCorrected    = 0
    linesRemoved      = 0
    linesInvoiced     = 0
    ordersInvoiced    = 0
    invoiceUnresolved = 0
    linesKgWritten    = 0
    followPolled      = 0
    mtRequested       = 0
    mtFailedWaiting   = 0
    mtCreated         = 0
    mtAdopted         = 0
    mtRefused         = 0
    repUnmatched      = 0
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
# The same two invoice fieldnames exist on Sales Order Item, per line.
$script:F_SO       = 'custom_sap_sales_order'
$script:F_SO_STAT  = 'custom_sap_sales_order_status'
$script:F_INV      = 'custom_sap_invoice'
$script:F_INV_DT   = 'custom_sap_invoice_date'
$script:F_SYNCED   = 'custom_sap_synced_at'
$script:F_ERR      = 'custom_sap_sync_error'

# Stage two (26 Sep 2026). Per line, what Hi-Tech actually sent - written by
# PASS B. The functions that read them name them as literals, so a test can
# extract those functions on their own.
$script:F_HT_DLV_KG = 'custom_hitech_delivered_kg'
$script:F_HT_INV_KG = 'custom_hitech_invoiced_kg'
$script:F_HT_REFS   = 'custom_hitech_delivery_refs'
# Per order, the Manna Treads Sales Order - written by PASS C. Only the
# dashboard's manna_mt_so_request sets custom_mt_so_requested and _by; this
# job reads them, and takes _by only from manna_treads.approvers.
$script:F_MT_REQ    = 'custom_mt_so_requested'
$script:F_MT_REQ_BY = 'custom_mt_so_requested_by'
$script:F_MT_SO     = 'custom_mt_sales_order'         # DocNum
$script:F_MT_ENTRY  = 'custom_mt_sales_order_entry'   # DocEntry - DocNum is not unique in SAP
$script:F_MT_ERR    = 'custom_mt_sync_error'
$script:F_MT_SYNCED = 'custom_mt_synced_at'

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

# (No customer lookup in PASS A: the Hi-Tech Sales Order always uses the fixed
# inter-company CardCode. custom_bp_code is read by PASS C only, for the
# stage-two order into MANNA_TREADS_LIVE - see Get-ErpCustomerForMt.)

function Get-ErpCustomerForMt {
    # @{ Code; Name }: the end customer's MANNA_TREADS_LIVE CardCode ('' when
    # it has none) and its ERPNext customer_name. The code is never guessed
    # from the name and never transformed - an order with no code is refused
    # (fixture rule customer_code). The name is what Test-MtCustomer holds the
    # Manna Treads CardName to, so a mistyped code that happens to be another
    # real customer is refused rather than billed.
    param([string] $Name)
    # .NET's Uri drops a trailing "." from a path segment, so "Sajeev Mathew &
    # Co." was asked for as "...Co" and 404ed. %2E survives it (11 Oct 2026).
    $resp = Invoke-ErpApi -Method 'GET' -Path ('/api/resource/Customer/' + ([uri]::EscapeDataString($Name) -replace '\.', '%2E'))
    $doc  = Get-JsonProp $resp 'data'
    if ($null -eq $doc) { throw "ERPNext returned no 'data' for Customer '$Name'" }
    return @{
        Code = (ConvertTo-CleanText (Get-JsonProp $doc 'custom_bp_code'))
        Name = (ConvertTo-CleanText (Get-JsonProp $doc 'customer_name'))
    }
}

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

function Invoke-MtSalesOrderPost {
    # PASS C's POST /Orders. Unlike New-SapSalesOrder (PASS A's, unchanged) it
    # does not throw: it hands back the HTTP status and SAP's error body, so
    # Get-MtPostFailure can tell SAP refusing THIS order from the call itself
    # failing. @{ Created = <SAP order, or $null>; Status; Body; Text }
    param([string] $BaseUrl, $Session, $Payload, [bool] $UseSkipCert)
    $splat = @{
        Method = 'Post'; Uri = "$BaseUrl/Orders"
        Body = ($Payload | ConvertTo-Json -Depth 8)
        ContentType = 'application/json'
        WebSession = $Session; ErrorAction = 'Stop'; TimeoutSec = 180
    }
    if ($UseSkipCert) { $splat.SkipCertificateCheck = $true }
    try {
        $created = Invoke-RestMethod @splat
        return @{ Created = $created; Status = $null; Body = ''; Text = '' }
    } catch {
        $er = $_
        $status = $null
        try { if ($er.Exception.PSObject.Properties['Response'] -and $er.Exception.Response) { $status = [int]$er.Exception.Response.StatusCode } } catch { }
        $body = ''
        if ($er.ErrorDetails -and $er.ErrorDetails.Message) { $body = "$($er.ErrorDetails.Message)" }
        return @{ Created = $null; Status = $status; Body = $body; Text = (Format-HttpError $er 'Manna Treads SAP POST /Orders') }
    }
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

function Resolve-InvoiceLineSoEntry {
    # Which sales order an A/R invoice LINE is for.
    #
    # An invoice line is based either on the sales order itself (BaseType 17,
    # BaseEntry = the order's DocEntry) or on a delivery (BaseType 15, BaseEntry
    # = the delivery's DocEntry, BaseLine = the delivery's line), which is then
    # followed back to that delivery line's own sales-order base. One invoice
    # cannot mix the two base types, but a pooled invoice can carry lines from
    # several sales orders, so this is resolved per line, never per invoice.
    #
    # $DnLineToSo maps "<delivery DocEntry>|<delivery LineNum>" to the sales
    # order DocEntry that delivery line was based on.
    #
    # The base types are literals here rather than the script's constants so
    # the function stands alone when a test extracts it.
    #
    # Returns the sales order DocEntry, or '' when the line is not based on a
    # sales order this run can see - a standalone invoice, or a delivery older
    # than the scan window.
    param($InvoiceLine, [hashtable] $DnLineToSo)
    $bt = [int](ConvertTo-Number (Get-JsonProp $InvoiceLine 'BaseType'))
    $be = "$(Get-JsonProp $InvoiceLine 'BaseEntry')".Trim()
    if ($be -eq '' -or $be -eq '0') { return '' }
    if ($bt -eq 17) { return $be }                              # based on the sales order
    if ($bt -eq 15) {                                           # based on a delivery
        $bl = "$(Get-JsonProp $InvoiceLine 'BaseLine')".Trim()
        $k  = "$be|$bl"
        if ($DnLineToSo -and $DnLineToSo.ContainsKey($k)) { return "$($DnLineToSo[$k])" }
    }
    return ''
}

function Select-CompletingInvoice {
    # Of the invoices that between them cover an order, the one that completed
    # it: the latest by DocDate, then by DocEntry. That is the invoice named on
    # the order once every line has gone. DocDate is ISO, so it sorts as text.
    param($Invoices)
    $best = $null
    foreach ($i in @($Invoices)) {
        if ($null -eq $i) { continue }
        if ($null -eq $best) { $best = $i; continue }
        $d  = "$(Get-JsonProp $i 'DocDate')"
        $bd = "$(Get-JsonProp $best 'DocDate')"
        if ($d -gt $bd) { $best = $i; continue }
        if ($d -eq $bd -and
            [int](ConvertTo-Number (Get-JsonProp $i 'DocEntry')) -gt [int](ConvertTo-Number (Get-JsonProp $best 'DocEntry'))) {
            $best = $i
        }
    }
    return $best
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

function Write-HitechKgUpdates {
    # PASS B's stage-two kilo writes for one order (Get-HitechKgUpdates'
    # Updates), one row at a time: a row that will not take its kilos does
    # not fail the order. Returns how many writes FAILED, so a caller about
    # to retire the order - or let it leave the followed set - can hold that
    # back until they have all gone in.
    param([string] $Name, $Updates, [string] $Label = 'PASS B')
    $failed = 0
    foreach ($ku in @($Updates)) {
        if ($null -eq $ku) { continue }
        try {
            Update-ErpOrderLine -RowName $ku.RowName -Fields $ku.Fields
            $script:Result.linesKgWritten++
            Write-Log INFO ("{0} {1}: line {2} Hi-Tech kilos - {3}" -f $Label, $Name, $ku.ItemCode, $ku.Note)
        } catch {
            $failed++
            Write-Log WARN ("{0} {1}: line {2} Hi-Tech kilos write failed - {3}" -f $Label, $Name, $ku.ItemCode, "$_")
        }
    }
    return $failed
}

function Limit-PassBHeaderOnKgFailure {
    # PASS B writes an order's Hi-Tech kilos BEFORE its header. When any of
    # them failed, the header must not move the order on as though they had
    # gone in, so two fields are held back until the next run writes both:
    #   - the SAP status: an order Hi-Tech has just closed would otherwise
    #     read 'ready' to the accountant, and be billable, on stale kilos;
    #   - the order-level invoice (and its date): writing it RETIRES the
    #     order from PASS B, and nothing would write the kilos again.
    # Pure. Removes the held-back keys from $Fields and returns their names.
    # The fieldnames are literals so a test can extract this on its own.
    param([hashtable] $Fields, [int] $KgFailed)
    $held = New-Object System.Collections.ArrayList
    if ($KgFailed -le 0 -or $null -eq $Fields) { return , $held }
    foreach ($k in @('custom_sap_sales_order_status', 'custom_sap_invoice', 'custom_sap_invoice_date')) {
        if ($Fields.ContainsKey($k)) { [void]$Fields.Remove($k); [void]$held.Add($k) }
    }
    return , $held
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

  So -DeliveredItems is required: the item codes a delivery note OR an A/R
  invoice actually carried for this order, which PASS B builds from
  $dnByEntryItem and $invByEntryItem. Closed WITH either is a finished line and
  is left alone. Closed WITHOUT either is the manufacturing team dropping an
  item, and the ERPNext row goes.

  Invoices count as well as deliveries because a line can be invoiced straight
  from the order with no delivery at all. Leaving invoices out would read such
  a line as closed-and-dropped and delete it - a line the customer has been
  billed for.

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
            if ($DeliveredItems.ContainsKey($code)) { continue }   # delivered or invoiced; finished, not dropped
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
# Stage two (26 Sep 2026) - what Hi-Tech actually sent, and the Manna Treads
# Sales Order. All pure except where the comment says otherwise;
# Test-MannaTreadsReorder.ps1 calls these same functions.
# --------------------------------------------------------------------------------

function ConvertTo-CleanText {
    # Trimmed text, with an unset Frappe value read back as 'null' taken as
    # empty - the same guard the rep lookup has.
    param($Value)
    $s = "$Value".Trim()
    if ($s -eq 'null') { return '' }
    return $s
}

function ConvertTo-FlagBool {
    # A Frappe Check (0/1), a JSON boolean, or either as text.
    param($Value)
    if ($Value -is [bool]) { return $Value }
    return ("$Value".Trim() -in @('1', 'true', 'yes'))
}

function Get-OptionalNullableInt {
    # Absent -> the default. Present but null or blank -> $null, which the
    # caller reads as "leave it off the SAP document and let SAP choose".
    param($Object, [string] $Name, $Default)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p) { return $Default }
    if ($null -eq $p.Value -or "$($p.Value)".Trim() -eq '') { return $null }
    return [int]$p.Value
}

function Get-RoundedHalfUp {
    # EXACTLY the dashboard's roundTo (client/src/domain/mannaTreadsReorder.ts):
    # take the binary noise off at 15 significant figures, then round the
    # DECIMAL value half away from zero. Both sides must bill the same order
    # to the same paisa, and the fixture case "half-paisa midpoints round UP"
    # pins it.
    #
    # Two ways this used to go wrong. [math]::Round takes a midpoint to EVEN
    # (10,272.625 -> 10,272.62). Floor(x * 100 + 0.5) on the raw double fixes
    # that but not the noise: 6029.7 / 60 is 100.49499999999999 as a double,
    # which that rounds to 100.49 where the decimal 100.495 is 100.50 - SAP
    # would have been keyed a paisa under the approved rate.
    #
    # roundTo's other branch - a number JavaScript prints in exponent form,
    # under 1e-6 or from 1e21 up - is copied too, so the two agree
    # everywhere, not just on money-sized figures.
    param([double] $Value, [int] $Digits)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 0.0 }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $g15 = $Value.ToString('G15', $inv)
    $exact = [double]::Parse($g15, [Globalization.NumberStyles]::Float, $inv)   # Number(n.toPrecision(15))
    $abs = [math]::Abs($exact)
    if ($abs -eq 0) { return 0.0 }
    if ($abs -lt 1e-6 -or $abs -ge 1e21) {
        # Math.round(abs * 10^d) / 10^d - nearest integer, a tie going up
        $p = [math]::Pow(10, $Digits)
        $x = $abs * $p
        $n = [math]::Floor($x)
        if (($x - $n) -ge 0.5) { $n = $n + 1 }
        $scaled = $n / $p
    } else {
        $dec = [decimal]::Parse($g15.TrimStart('-'), [Globalization.NumberStyles]::Float, $inv)
        $scaled = [double][decimal]::Round($dec, $Digits, [MidpointRounding]::AwayFromZero)
    }
    if ($exact -lt 0) { return [double](-$scaled) }
    return [double]$scaled
}

function Get-MtGstPercent {
    # GST on a Manna Treads tread-rubber sale, and the approved rate INCLUDES
    # it - both fixed, not configurable (26 Sep 2026): the fixture's
    # gst_percent and its rule the_price_includes_gst say so, and the
    # dashboard hard-codes the same 18 (GST_PERCENT in
    # client/src/domain/mannaTreadsReorder.ts). A knob here could only make
    # the sync bill a different figure from the one the accountant approved.
    # Test-MannaTreadsReorder.ps1 checks this against the fixture.
    return 18
}

function Test-SapDocumentCounts {
    # Whether a SAP delivery or invoice is a live document.
    #
    # Cancelling a delivery does not remove it. The original stays, reading
    # Cancelled=tYES / CancelStatus=csYes, and SAP posts a SECOND delivery -
    # the reversal - with CancelStatus=csCancellation and lines based on the
    # first (BaseType 15). Neither is goods that left the factory. Until
    # 26 Sep 2026 the delivery scan did not ask, so a cancelled delivery
    # counted as shipped in the line reconcile.
    #
    # Only csNo counts. The delivery scan selects CancelStatus; the Cancelled
    # fallback is for a document read without it (the invoice scan selects
    # only Cancelled - a cancelled invoice's reversal is a credit memo, which
    # that scan never sees).
    param($Document)
    $cs = "$(Get-JsonProp $Document 'CancelStatus')".Trim()
    if ($cs -ne '') { return ($cs -eq 'csNo') }
    return ("$(Get-JsonProp $Document 'Cancelled')".Trim() -ne 'tYES')
}

function Format-HitechDeliveryRef {
    # "DN 4 (18-09-2026)" - how a delivery is named to the accountant. The date
    # is taken as text, so it is SAP's own whatever the server's time zone.
    param($DeliveryNote)
    $num = "$(Get-JsonProp $DeliveryNote 'DocNum')".Trim()
    $raw = "$(Get-JsonProp $DeliveryNote 'DocDate')".Trim()
    $m = [regex]::Match($raw, '^(\d{4})-(\d{2})-(\d{2})')
    if ($m.Success) { return ('DN {0} ({1}-{2}-{3})' -f $num, $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[1].Value) }
    if ($raw -eq '') { return "DN $num" }
    return "DN $num ($raw)"
}

function Add-HitechDeliveredKg {
    # One Hi-Tech delivery note into the per-sales-order-LINE maps:
    #   $KgByLine   "SO DocEntry|SO LineNum" -> kilos delivered from that line
    #   $RefsByLine "SO DocEntry|SO LineNum" -> ArrayList of "DN <n> (<date>)"
    # Keyed on BaseLine, not the item: one delivery can carry several orders,
    # and the line is what the goods were drawn from. Quantity is kilos, as on
    # the sales order it copies. Returns $false, adding nothing, for a
    # cancelled delivery or a reversal (Test-SapDocumentCounts).
    param($DeliveryNote, [hashtable] $KgByLine, [hashtable] $RefsByLine)
    if (-not (Test-SapDocumentCounts $DeliveryNote)) { return $false }
    $ref = Format-HitechDeliveryRef $DeliveryNote
    foreach ($dl in @(Get-JsonProp $DeliveryNote 'DocumentLines')) {
        if ($null -eq $dl) { continue }
        if ([int](ConvertTo-Number (Get-JsonProp $dl 'BaseType')) -ne 17) { continue }
        $be = "$(Get-JsonProp $dl 'BaseEntry')".Trim()
        $bl = "$(Get-JsonProp $dl 'BaseLine')".Trim()
        if ($be -eq '' -or $be -eq '0' -or $bl -eq '') { continue }
        $k = "$be|$bl"
        $q = ConvertTo-Number (Get-JsonProp $dl 'Quantity')
        if ($KgByLine.ContainsKey($k)) { $KgByLine[$k] = $KgByLine[$k] + $q } else { $KgByLine[$k] = $q }
        if (-not $RefsByLine.ContainsKey($k)) { $RefsByLine[$k] = New-Object System.Collections.ArrayList }
        if (-not $RefsByLine[$k].Contains($ref)) { [void]$RefsByLine[$k].Add($ref) }
    }
    return $true
}

function Add-HitechInvoicedKg {
    # One Hi-Tech A/R invoice into "SO DocEntry|SO LineNum" -> kilos invoiced
    # STRAIGHT from that sales-order line (BaseType 17). A line based on a
    # delivery (BaseType 15) is not added: those kilos are the delivery's.
    # So these are always goods that left WITHOUT a delivery note - and the
    # fixture rule delivery_wins ignores them on an order with any delivery.
    # PASS C therefore refuses such a mixed order (Test-MtMixedBasis) rather
    # than bill it short. Returns $false, adding nothing, for a cancelled
    # invoice.
    param($Invoice, [hashtable] $KgByLine)
    if (-not (Test-SapDocumentCounts $Invoice)) { return $false }
    foreach ($il in @(Get-JsonProp $Invoice 'DocumentLines')) {
        if ($null -eq $il) { continue }
        if ([int](ConvertTo-Number (Get-JsonProp $il 'BaseType')) -ne 17) { continue }
        $be = "$(Get-JsonProp $il 'BaseEntry')".Trim()
        $bl = "$(Get-JsonProp $il 'BaseLine')".Trim()
        if ($be -eq '' -or $be -eq '0' -or $bl -eq '') { continue }
        $k = "$be|$bl"
        $q = ConvertTo-Number (Get-JsonProp $il 'Quantity')
        if ($KgByLine.ContainsKey($k)) { $KgByLine[$k] = $KgByLine[$k] + $q } else { $KgByLine[$k] = $q }
    }
    return $true
}

<#
.SYNOPSIS
  Which ERPNext lines need their Hi-Tech delivered / invoiced kilos rewritten.
  Plans only; writes nothing.

.DESCRIPTION
  The kilos are per SAP sales-order LINE ("DocEntry|LineNum"). ERPNext keeps
  no SAP line number, so the SAP line is turned into its item code through the
  order's own DocumentLines and matched to the ERPNext row by item, as the
  reconcile and the invoice join are. An item on two lines, either side,
  cannot be told apart and is skipped with a note - the reconcile's rule.

  Written only when a figure moves by more than the tolerance (0.0005 kg; the
  fields hold 3 decimals) or the refs text changes: this runs every pass for
  every open order, and an unchanged write still bumps `modified`.

  AN ORDER OLDER THAN THE SCAN WINDOW KEEPS WHAT WAS LAST RECORDED. The scans
  look back delivery_scan_days / invoice_scan_days. Once an order's own
  DocDate is older than that, a delivery of it may have aged out of the scan,
  and a fresh figure could bill the customer short. With
  -DeliveryScanComplete (or -InvoiceScanComplete) false that figure is not
  rewritten, and a skip says so whenever it would have changed.

.OUTPUTS
  @{ Updates = <ArrayList of @{ RowName; ItemCode; Fields; Note }>;
     Skips   = <ArrayList of @{ ItemCode; Note }> }
#>
function Get-HitechKgUpdates {
    param(
        [Parameter(Mandatory = $true)] $SapLines,
        [Parameter(Mandatory = $true)] $ErpItems,
        [Parameter(Mandatory = $true)] [string] $SoEntry,
        [hashtable] $DeliveredKg = @{},
        [hashtable] $InvoicedKg = @{},
        [hashtable] $DeliveryRefs = @{},
        [bool] $DeliveryScanComplete = $true,
        [bool] $InvoiceScanComplete = $true,
        [double] $Tolerance = 0.0005
    )
    $out = @{ Updates = (New-Object System.Collections.ArrayList); Skips = (New-Object System.Collections.ArrayList) }

    # Per item: what its SAP line received, and whether the item is on two.
    $sapBy = @{}; $sapDup = @{}
    foreach ($l in @($SapLines)) {
        if ($null -eq $l) { continue }
        $code = "$(Get-JsonProp $l 'ItemCode')".Trim()
        $ln   = "$(Get-JsonProp $l 'LineNum')".Trim()
        if ($code -eq '' -or $ln -eq '') { continue }
        if ($sapBy.ContainsKey($code)) { $sapDup[$code] = $true; continue }
        $k = "$SoEntry|$ln"
        $d = 0.0; if ($DeliveredKg.ContainsKey($k)) { $d = [double]$DeliveredKg[$k] }
        $i = 0.0; if ($InvoicedKg.ContainsKey($k))  { $i = [double]$InvoicedKg[$k] }
        $r = '';  if ($DeliveryRefs.ContainsKey($k)) { $r = (($DeliveryRefs[$k]) -join ', ') }
        $sapBy[$code] = @{ Delivered = $d; Invoiced = $i; Refs = $r }
    }
    $erpSeen = @{}; $erpDup = @{}
    foreach ($it in @($ErpItems)) {
        if ($null -eq $it) { continue }
        $code = "$(Get-JsonProp $it 'item_code')".Trim()
        if ($code -eq '') { continue }
        if ($erpSeen.ContainsKey($code)) { $erpDup[$code] = $true }
        $erpSeen[$code] = $true
    }

    foreach ($it in @($ErpItems)) {
        if ($null -eq $it) { continue }
        $code    = "$(Get-JsonProp $it 'item_code')".Trim()
        $rowName = "$(Get-JsonProp $it 'name')".Trim()
        if ($code -eq '' -or $rowName -eq '') { continue }
        # Not on the SAP order at all: the reconcile's business, not this.
        if (-not $sapBy.ContainsKey($code)) { continue }
        if ($sapDup.ContainsKey($code) -or $erpDup.ContainsKey($code)) {
            [void]$out.Skips.Add(@{ ItemCode = $code; Note = "item $code appears on more than one line - cannot tell which one Hi-Tech sent, so no kilos are written for it." })
            continue
        }

        $s    = $sapBy[$code]
        $newD = Get-RoundedHalfUp $s.Delivered 3
        $newI = Get-RoundedHalfUp $s.Invoiced 3
        $newR = $s.Refs
        $oldD = ConvertTo-Number (Get-JsonProp $it 'custom_hitech_delivered_kg')
        $oldI = ConvertTo-Number (Get-JsonProp $it 'custom_hitech_invoiced_kg')
        $oldR = ConvertTo-CleanText (Get-JsonProp $it 'custom_hitech_delivery_refs')

        $f = @{}
        $notes = New-Object System.Collections.ArrayList
        $dMoved = ([math]::Abs($newD - $oldD) -gt $Tolerance)
        if ($dMoved -or $newR -ne $oldR) {
            if (-not $DeliveryScanComplete) {
                [void]$out.Skips.Add(@{ ItemCode = $code; Note = "item ${code}: the deliveries seen add up to $newD kg against $oldD kg recorded, but the order is older than the delivery scan - left as recorded." })
            } else {
                if ($dMoved) { $f['custom_hitech_delivered_kg'] = $newD; [void]$notes.Add("delivered $oldD -> $newD kg") }
                if ($newR -ne $oldR) { $f['custom_hitech_delivery_refs'] = $newR }
            }
        }
        if ([math]::Abs($newI - $oldI) -gt $Tolerance) {
            if (-not $InvoiceScanComplete) {
                [void]$out.Skips.Add(@{ ItemCode = $code; Note = "item ${code}: the direct invoices seen add up to $newI kg against $oldI kg recorded, but the order is older than the invoice scan - left as recorded." })
            } else {
                $f['custom_hitech_invoiced_kg'] = $newI
                [void]$notes.Add("invoiced direct $oldI -> $newI kg")
            }
        }
        if ($f.Count -gt 0) {
            $note = ($notes -join ', ')
            if ($note -eq '') { $note = 'delivery refs' }
            [void]$out.Updates.Add(@{ RowName = $rowName; ItemCode = $code; Fields = $f; Note = $note })
        }
    }
    return $out
}

function ConvertTo-MtReorderInput {
    # An ERPNext Sales Order, read with its items, in the shape of the shared
    # fixture's "order" - what Get-MtReorderPlan takes. $BpCode is the end
    # customer's Customer.custom_bp_code. qty is ROLLS whatever the uom says,
    # so it is never read; custom_total_weight is the ordered kilos.
    param([Parameter(Mandatory = $true)] $Doc, [string] $BpCode)
    $lines = New-Object System.Collections.ArrayList
    foreach ($it in @(Get-JsonProp $Doc 'items')) {
        if ($null -eq $it) { continue }
        [void]$lines.Add([pscustomobject]@{
            item         = (ConvertTo-CleanText (Get-JsonProp $it 'item_code'))
            ordered_kg   = (ConvertTo-Number (Get-JsonProp $it 'custom_total_weight'))
            amount       = (ConvertTo-Number (Get-JsonProp $it 'amount'))
            rate_per_kg  = (ConvertTo-Number (Get-JsonProp $it 'custom_rate_per_kg'))
            delivered_kg = (ConvertTo-Number (Get-JsonProp $it 'custom_hitech_delivered_kg'))
            invoiced_kg  = (ConvertTo-Number (Get-JsonProp $it 'custom_hitech_invoiced_kg'))
            refs         = (ConvertTo-CleanText (Get-JsonProp $it 'custom_hitech_delivery_refs'))
        })
    }
    return [pscustomobject]@{
        sap_sales_order  = (ConvertTo-CleanText (Get-JsonProp $Doc 'custom_sap_sales_order'))
        sap_status       = (ConvertTo-CleanText (Get-JsonProp $Doc 'custom_sap_sales_order_status'))
        customer_mt_code = (ConvertTo-CleanText $BpCode)
        mt_sales_order   = (ConvertTo-CleanText (Get-JsonProp $Doc 'custom_mt_sales_order'))
        mt_requested     = (ConvertTo-FlagBool (Get-JsonProp $Doc 'custom_mt_so_requested'))
        mt_error         = (ConvertTo-CleanText (Get-JsonProp $Doc 'custom_mt_sync_error'))
        lines            = $lines
    }
}

<#
.SYNOPSIS
  The shared stage-two rule: what the Manna Treads Sales Order for one Hi-Tech
  order bills, and which state that order is in. Pure.

.DESCRIPTION
  shared/fixtures/manna_treads_reorder.json is the specification - its
  "rules" block - and the dashboard implements the same rule in TypeScript
  (client/src/domain, tested against the same file). Test-MannaTreadsReorder.ps1
  runs every fixture case through THIS function. Change the fixture and both
  implementations in the same commit.

  In short: bill what Hi-Tech DELIVERED, line by line - or, only when nothing
  was delivered at all, what it invoiced; never both, because the invoice of a
  delivered order is drawn from the delivery. Leave out a line with nothing.
  Price at the manager's approved rate (amount / ordered kilos), which is
  GST-inclusive, so the SAP line carries it net and SAP adds the tax back.

  $Order is the fixture's shape (ConvertTo-MtReorderInput builds it from an
  ERPNext order). The lines and total are worked out whatever the state: PASS C
  needs them for an order that is queued or failed, not only one that is ready.

.OUTPUTS
  @{ State; Basis = 'delivered'|'invoiced';
     Lines = <ArrayList of @{ Item; Kg; Rate; Amount; UnitPriceNet; Refs }>; Total }
#>
function Get-MtReorderPlan {
    # Every rounding below is Get-RoundedHalfUp, the dashboard's roundTo, at
    # the same places the dashboard rounds: kilos to 3, rate and amount to 2,
    # the net unit price to 6, the total to 2. GST is Get-MtGstPercent and
    # the rate always includes it - neither is a parameter any more.
    param([Parameter(Mandatory = $true)] $Order)
    $src = @(Get-JsonProp $Order 'lines' | Where-Object { $null -ne $_ })

    # delivery_wins: one delivered line anywhere puts the whole order on the
    # delivered basis, and its invoiced figures are then ignored.
    $basis = 'invoiced'
    foreach ($l in $src) {
        if ((Get-RoundedHalfUp (ConvertTo-Number (Get-JsonProp $l 'delivered_kg')) 3) -gt 0) { $basis = 'delivered'; break }
    }

    # the_price_includes_gst - always.
    $divisor = 1 + ((Get-MtGstPercent) / 100)

    $lines = New-Object System.Collections.ArrayList
    $total = 0.0
    foreach ($l in $src) {
        if ($basis -eq 'delivered') { $kg = Get-RoundedHalfUp (ConvertTo-Number (Get-JsonProp $l 'delivered_kg')) 3 }
        else                        { $kg = Get-RoundedHalfUp (ConvertTo-Number (Get-JsonProp $l 'invoiced_kg')) 3 }
        if ($kg -le 0) { continue }                           # lines_with_nothing_are_left_out

        # the_price_is_the_approved_one: amount / ordered kilos keeps a legacy
        # discounted line at its net price; rate_per_kg only when there are no
        # ordered kilos to divide by.
        $ordered = ConvertTo-Number (Get-JsonProp $l 'ordered_kg')
        if ($ordered -gt 0) { $rate = Get-RoundedHalfUp ((ConvertTo-Number (Get-JsonProp $l 'amount')) / $ordered) 2 }
        else                { $rate = Get-RoundedHalfUp (ConvertTo-Number (Get-JsonProp $l 'rate_per_kg')) 2 }

        $amount = Get-RoundedHalfUp ($kg * $rate) 2
        $total += $amount
        [void]$lines.Add(@{
            Item         = (ConvertTo-CleanText (Get-JsonProp $l 'item'))
            Kg           = [double]$kg
            Rate         = [double]$rate
            Amount       = [double]$amount
            UnitPriceNet = (Get-RoundedHalfUp ($rate / $divisor) 6)   # the_price_includes_gst
            Refs         = (ConvertTo-CleanText (Get-JsonProp $l 'refs'))
        })
    }

    # states_and_precedence, in the fixture's order.
    $sapSo     = ConvertTo-CleanText (Get-JsonProp $Order 'sap_sales_order')
    $status    = ConvertTo-CleanText (Get-JsonProp $Order 'sap_status')
    $requested = ConvertTo-FlagBool (Get-JsonProp $Order 'mt_requested')
    $err       = ConvertTo-CleanText (Get-JsonProp $Order 'mt_error')
    $state = 'ready'
    if     ($sapSo -eq '')                                                        { $state = 'not_in_sap' }
    elseif ((ConvertTo-CleanText (Get-JsonProp $Order 'mt_sales_order')) -ne '')  { $state = 'created' }
    elseif ($status -eq 'bost_Cancelled')                                         { $state = 'cancelled' }
    elseif ($status -ne 'bost_Close')                                             { $state = 'at_hitech' }
    elseif ($lines.Count -eq 0)                                                   { $state = 'nothing_delivered' }
    elseif ($requested -and $err -ne '')                                          { $state = 'failed' }
    elseif ($requested)                                                           { $state = 'queued' }
    elseif ((ConvertTo-CleanText (Get-JsonProp $Order 'customer_mt_code')) -eq '') { $state = 'blocked' }

    return @{ State = $state; Basis = $basis; Lines = $lines; Total = (Get-RoundedHalfUp $total 2) }
}

function Get-MtPlanRefusal {
    # What PASS C does with a planned order: 'create'; 'skip', with nothing to
    # say (not asked for, already created, or failed and waiting for the
    # accountant's Try again); or 'refuse', with the reason that goes into
    # custom_mt_sync_error.
    #
    # EVERY refusal is about the order, not the run (26 Sep 2026): it is
    # written on the order, the order reads 'failed' on the accountant's
    # screen with the reason and a Try again, and the run is NOT failed by it.
    # Only a transient failure fails the run - see Get-MtPostFailure.
    # manna_mt_so_request checks the Hi-Tech state when he approves, so a
    # state refusal here means SAP moved after he did.
    param([Parameter(Mandatory = $true)] $Plan, [string] $CustomerCode, [string] $HitechStatus, [string] $Unit)
    $r = @{ Action = 'refuse'; Message = '' }
    switch ($Plan.State) {
        'created'           { $r.Action = 'skip'; return $r }
        'ready'             { $r.Action = 'skip'; return $r }   # not asked for
        'blocked'           { $r.Action = 'skip'; return $r }   # not asked for
        'failed'            { $r.Action = 'skip'; return $r }   # waits for Try again, which clears the error
        'not_in_sap'        { $r.Message = 'Not in Hi-Tech SAP yet - there is nothing to re-create.'; return $r }
        'cancelled'         { $r.Message = 'Hi-Tech cancelled this order - there is nothing to bill.'; return $r }
        'at_hitech'         { $r.Message = ("Hi-Tech has not closed this order yet (SAP status {0}) - it may still be delivered further." -f $(if ("$HitechStatus".Trim()) { "$HitechStatus".Trim() } else { 'unknown' })); return $r }
        'nothing_delivered' { $r.Message = 'Hi-Tech closed this order with nothing delivered or invoiced - there is nothing to bill.'; return $r }
    }
    if ($Plan.State -ne 'queued') { $r.Message = "Unknown plan state '$($Plan.State)' - refusing rather than guessing."; return $r }

    # Asked for, finished at Hi-Tech, something to bill. What the rule leaves
    # to the sync: whose order it is, and what it costs.
    $u = ConvertTo-CleanText $Unit
    if ($u -ne '' -and $u -ne 'Manna Treads') { $r.Message = "This is a $u order - it is not Manna Treads' to invoice."; return $r }
    if ((ConvertTo-CleanText $CustomerCode) -eq '') { $r.Message = 'The customer has no Manna Treads customer code (Customer.custom_bp_code) - set it on the Customer; it is never guessed from the name.'; return $r }
    $unpriced = @($Plan.Lines | Where-Object { $_.Rate -le 0 } | ForEach-Object { $_.Item })
    if ($unpriced.Count -gt 0) { $r.Message = ("No approved price on {0} - refusing to let Manna Treads SAP price it from its own list." -f ($unpriced -join ', ')); return $r }

    $r.Action = 'create'
    return $r
}

function Test-MtDuplicateLines {
    # '' unless an item code is on more than one ERPNext line of the order.
    #
    # Hi-Tech's kilos are matched to an ERPNext row by item code, so for an
    # item on two rows PASS B cannot tell which one Hi-Tech sent and writes
    # neither (Get-HitechKgUpdates skips it). Both rows then read 0 kilos, the
    # plan leaves them out as lines with nothing, and the order would post
    # SHORT. So the whole order is refused - never posted with them dropped.
    # Read from the ERPNext lines, not the plan: the plan has already lost them.
    param($Items)
    $count = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $c = ConvertTo-CleanText (Get-JsonProp $it 'item_code')
        if ($c -eq '') { continue }
        $k = $c.ToUpperInvariant()
        if ($count.ContainsKey($k)) { $count[$k] = $count[$k] + 1 }
        else { $count[$k] = 1; [void]$order.Add($c) }
    }
    $parts = New-Object System.Collections.ArrayList
    foreach ($c in $order) {
        $n = $count[$c.ToUpperInvariant()]
        if ($n -lt 2) { continue }
        $word = if ($n -eq 2) { 'two' } else { "$n" }
        [void]$parts.Add("$c is on $word lines of this order")
    }
    if ($parts.Count -eq 0) { return '' }
    return (($parts -join '; ') + "; Hi-Tech's kilos cannot be split between them - raise it in SAP by hand.")
}

function Test-MtAllowedItems {
    # '' when every item to be billed may go on a Manna Treads order, else
    # why not. Only the allowlist's items may (manna_treads.item_allowlist;
    # by default the ten SYNC TEST items I-14636..I-14645, the only codes
    # created identically in both companies - the user, 26 Sep 2026: "only
    # the test items for now"). A real Hi-Tech code can exist in Manna
    # Treads SAP as a DIFFERENT tread, so "the code exists there" is not
    # enough to bill it; Test-MtItems also compares the names.
    param([string[]] $Codes, [string[]] $Allowlist)
    $allowed = @{}
    foreach ($a in @($Allowlist)) { $t = "$a".Trim(); if ($t -ne '') { $allowed[$t.ToUpperInvariant()] = $true } }
    $bad = New-Object System.Collections.ArrayList
    foreach ($c in @($Codes)) {
        $t = "$c".Trim()
        if ($t -eq '' -or $bad.Contains($t)) { continue }
        if (-not $allowed.ContainsKey($t.ToUpperInvariant())) { [void]$bad.Add($t) }
    }
    if ($bad.Count -eq 0) { return '' }
    if ($bad.Count -eq 1) { return "$($bad[0]) is not set up for Manna Treads sales orders yet." }
    return "$($bad -join ', ') are not set up for Manna Treads sales orders yet."
}

function Test-MtApprover {
    # '' when the order was asked for by one of manna_treads.approvers, else
    # why not.
    #
    # manna_mt_so_request - the only thing meant to set custom_mt_so_requested
    # - checks the caller is the accountant and records who it was in
    # custom_mt_so_requested_by. But both fields are permlevel 0, so any
    # Sales Order writer can set them over REST without that check, and this
    # sync's ERPNext user cannot read User or Has Role to ask who the
    # accountant is. So the approvers are named in config (by default the one
    # user with custom_is_accountant, read 26 Sep 2026). This catches a flag
    # set by anything but the request script; it does not stop someone who
    # also forges _by - that needs the fields at permlevel 1 (see README).
    param([string] $RequestedBy, [string[]] $Approvers)
    $who = ConvertTo-CleanText $RequestedBy
    if ($who -eq '') {
        return 'Not approved by the accountant: nobody is recorded as asking for it (custom_mt_so_requested_by is empty). Approve it on the Manna Treads screen.'
    }
    foreach ($a in @($Approvers)) {
        $t = "$a".Trim()
        if ($t -ne '' -and $t.ToLowerInvariant() -eq $who.ToLowerInvariant()) { return '' }
    }
    return "Not approved by the accountant: it was asked for by $who, who is not one of manna_treads.approvers. Approve it on the Manna Treads screen."
}

function Test-MtSharedHitechOrder {
    # '' unless another live ERPNext order carries the same Hi-Tech SO.
    #
    # PASS B finds the Hi-Tech order by DocNum, so a second ERPNext order
    # pointing at the same DocNum - a Desk "Duplicate" of a finished order
    # (custom_sap_sales_order is copied, the kilos are not), or a hand-typed
    # number - would be given that order's kilos and billed a second time
    # for goods Hi-Tech delivered once. Both orders are refused until one is
    # gone. $Others is the ERPNext list read by custom_sap_sales_order,
    # excluding this order and anything cancelled.
    param([string] $HitechSo, $Others)
    $names = New-Object System.Collections.ArrayList
    foreach ($o in @($Others)) {
        if ($null -eq $o) { continue }
        $n = ConvertTo-CleanText (Get-JsonProp $o 'name')
        if ($n -ne '' -and -not $names.Contains($n)) { [void]$names.Add($n) }
    }
    if ($names.Count -eq 0) { return '' }
    return ("Hi-Tech SO {0} is also on {1} - one Hi-Tech order can be billed once; raise it by hand." -f "$HitechSo".Trim(), ($names -join ', '))
}

function Test-MtMixedBasis {
    # '' unless the order is billed on its deliveries while Hi-Tech also
    # invoiced part of it STRAIGHT from the sales order.
    #
    # custom_hitech_invoiced_kg counts only invoice lines drawn straight from
    # the order (Add-HitechInvoicedKg), so on an order with any delivery it is
    # always goods that left WITHOUT one - a line invoiced direct, or the rest
    # of a part-delivered line. The fixture rule delivery_wins bills such an
    # order on deliveries alone and would leave those kilos unbilled. Until
    # the rule itself is decided (fixture and both implementations), the sync
    # refuses the order rather than post it short.
    param([Parameter(Mandatory = $true)] $Plan, $Items)
    if ("$($Plan.Basis)" -ne 'delivered') { return '' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $kg = Get-RoundedHalfUp (ConvertTo-Number (Get-JsonProp $it 'custom_hitech_invoiced_kg')) 3
        if ($kg -gt 0) { [void]$parts.Add(("{0} ({1} kg)" -f (ConvertTo-CleanText (Get-JsonProp $it 'item_code')), $kg)) }
    }
    if ($parts.Count -eq 0) { return '' }
    return ("Hi-Tech invoiced {0} straight from its order without a delivery, and delivered the rest - billing on the deliveries alone would leave that out. Raise it by hand." -f ($parts -join ', '))
}

function Get-HitechOwnerNote {
    # '' when a Hi-Tech Sales Order may be this ERPNext order's, else why not:
    # its NumAtCard names ANOTHER order. PASS A stamps the ERPNext name there
    # (and adopts by it), so that is Hi-Tech's own record of whose order it
    # is. An empty NumAtCard is no evidence either way (a hand-made SAP
    # order). PASS B uses this to keep another order's kilos off this one;
    # PASS C refuses on it. Pure.
    param($SapOrder, [string] $OrderName)
    if ($null -eq $SapOrder) { return '' }
    $ntc = ConvertTo-CleanText (Get-JsonProp $SapOrder 'NumAtCard')
    if ($ntc -eq '' -or $ntc -eq "$OrderName".Trim()) { return '' }
    return ("Hi-Tech SO {0} carries NumAtCard '{1}', not this order" -f (ConvertTo-CleanText (Get-JsonProp $SapOrder 'DocNum')), $ntc)
}

function Resolve-HitechOrderFor {
    # PASS C's reading of which Hi-Tech Sales Order is this ERPNext order's,
    # from the Orders this run read by DocNum. Pure.
    # @{ Order = <the SAP order, or $null>; Problem = '' or the refusal }.
    #
    # Stricter than PASS B's (which is left as it was): DocNum is not unique
    # in Hi-Tech SAP, so of several orders with the number exactly the one
    # carrying this order's name in NumAtCard is it; and a lone one must not
    # carry ANOTHER order's name (Get-HitechOwnerNote).
    param($Candidates, [string] $HitechSo, [string] $OrderName)
    $so = "$HitechSo".Trim()
    $live = New-Object System.Collections.ArrayList
    if ($null -ne $Candidates) { foreach ($x in $Candidates) { if ($null -ne $x) { [void]$live.Add($x) } } }
    if ($live.Count -eq 0) {
        return @{ Order = $null; Problem = "Hi-Tech SO $so was not found in Hi-Tech SAP - check custom_sap_sales_order on this order." }
    }
    if ($live.Count -eq 1) {
        $note = Get-HitechOwnerNote -SapOrder $live[0] -OrderName $OrderName
        if ($note) { return @{ Order = $null; Problem = "$note - one Hi-Tech order can be billed once; raise it by hand." } }
        return @{ Order = $live[0]; Problem = '' }
    }
    foreach ($x in $live) {
        if ((ConvertTo-CleanText (Get-JsonProp $x 'NumAtCard')) -eq "$OrderName".Trim()) { return @{ Order = $x; Problem = '' } }
    }
    return @{ Order = $null; Problem = ("Hi-Tech SAP has {0} orders numbered {1} and none carries this order's name in NumAtCard - cannot tell which is this one; raise it by hand." -f $live.Count, $so) }
}

<#
.SYNOPSIS
  Whether Hi-Tech's own Sales Order, read THIS run, backs exactly the kilos
  this ERPNext order is about to bill. Pure.

.DESCRIPTION
  PASS C bills from the kilos PASS B recorded on the ERPNext rows. Those are
  matched to Hi-Tech's lines by item code, so anything PASS B could not match
  is simply missing from them, and the plan would post the order SHORT with
  nothing but a PASS B WARN in a log. So before posting, the Hi-Tech order is
  checked against this run's delivery and invoice scans - the same maps PASS
  B writes from - and the order is refused, in plain words, when:

    * Hi-Tech SAP does not show it closed now;
    * it is dated before either scan window, so its deliveries may have aged
      out of what the scans can see (PASS B stops refreshing such an order);
    * Hi-Tech sent an item that is on two of its lines (PASS B cannot tell
      which is which and writes neither);
    * Hi-Tech sent an item on a line this ERPNext order does not have (a
      line added at the factory - PASS B has no row to write it to);
    * an ERPNext row carries Hi-Tech kilos for an item not on Hi-Tech's order;
    * the kilos recorded on a row differ from what Hi-Tech shows now
      (Stale = $true: PASS B has not caught up - see the caller).

  An item on two ERPNext rows is Test-MtDuplicateLines' refusal, not this.

.OUTPUTS
  @{ Message = '' or the refusal; Stale = <bool> }
#>
function Get-MtHitechCheck {
    param(
        [Parameter(Mandatory = $true)] $HitechOrder,
        $ErpItems,
        [hashtable] $DeliveredKg = @{},
        [hashtable] $InvoicedKg = @{},
        [string] $DeliveryCutoff = '',
        [string] $InvoiceCutoff = '',
        [double] $Tolerance = 0.0005
    )
    $out = @{ Message = ''; Stale = $false }
    $num    = ConvertTo-CleanText (Get-JsonProp $HitechOrder 'DocNum')
    $entry  = ConvertTo-CleanText (Get-JsonProp $HitechOrder 'DocEntry')
    $status = Resolve-SoStatus $HitechOrder
    if ($status -ne 'bost_Close') {
        $out.Message = ("Hi-Tech SAP shows its SO {0} as {1} now, not closed - it may still be delivered further." -f $num, $(if ($status) { $status } else { 'unknown' }))
        return $out
    }

    $soDate = ConvertTo-DateOnly (Get-JsonProp $HitechOrder 'DocDate')
    $late = "$DeliveryCutoff".Trim()
    if ("$InvoiceCutoff".Trim() -gt $late) { $late = "$InvoiceCutoff".Trim() }
    if ($late -ne '' -and (-not $soDate -or $soDate -lt $late)) {
        $out.Message = ("Hi-Tech SO {0} is dated {1}, before the sync's delivery and invoice scans (from {2}) - its kilos may be incomplete. Raise it by hand, or widen delivery_scan_days / invoice_scan_days." -f $num, $(if ($soDate) { $soDate } else { 'unknown' }), $late)
        return $out
    }

    # Hi-Tech's lines, per item, with what each was sent.
    $sapLines = @(Get-JsonProp $HitechOrder 'DocumentLines' | Where-Object { $null -ne $_ })
    $erpRows  = @(@($ErpItems) | Where-Object { $null -ne $_ })
    if ($entry -eq '' -or $sapLines.Count -eq 0 -or $erpRows.Count -eq 0) {
        $out.Message = "Hi-Tech SO $num or this order read back with no lines - nothing can be checked; raise it by hand."
        return $out
    }
    $sapCodes = New-Object System.Collections.ArrayList
    $sapN = @{}; $sapKg = @{}
    foreach ($l in $sapLines) {
        $code = ConvertTo-CleanText (Get-JsonProp $l 'ItemCode')
        $ln   = ConvertTo-CleanText (Get-JsonProp $l 'LineNum')
        if ($code -eq '' -or $ln -eq '') { continue }
        $k = "$entry|$ln"
        $kg = 0.0
        if ($DeliveredKg.ContainsKey($k)) { $kg += [double]$DeliveredKg[$k] }
        if ($InvoicedKg.ContainsKey($k))  { $kg += [double]$InvoicedKg[$k] }
        if ($sapN.ContainsKey($code)) { $sapN[$code]++; $sapKg[$code] += $kg }
        else { $sapN[$code] = 1; $sapKg[$code] = $kg; [void]$sapCodes.Add($code) }
    }
    $erpN = @{}
    foreach ($it in $erpRows) {
        $code = ConvertTo-CleanText (Get-JsonProp $it 'item_code')
        if ($code -eq '') { continue }
        if ($erpN.ContainsKey($code)) { $erpN[$code]++ } else { $erpN[$code] = 1 }
    }

    $problems = New-Object System.Collections.ArrayList
    foreach ($code in $sapCodes) {
        $kg = Get-RoundedHalfUp $sapKg[$code] 3
        if ($kg -le $Tolerance) { continue }                       # nothing sent: nothing to lose
        $n = $sapN[$code]
        if ($n -gt 1) {
            [void]$problems.Add(("Hi-Tech has {0} on {1} lines of its order ({2} kg sent) and its kilos cannot be matched to this order's line" -f $code, $(if ($n -eq 2) { 'two' } else { "$n" }), $kg))
        } elseif (-not $erpN.ContainsKey($code)) {
            [void]$problems.Add(("Hi-Tech delivered {0} ({1} kg) on a line this order cannot be matched to" -f $code, $kg))
        }
    }
    foreach ($it in $erpRows) {
        $code = ConvertTo-CleanText (Get-JsonProp $it 'item_code')
        if ($code -eq '' -or $sapN.ContainsKey($code)) { continue }
        $rec = (ConvertTo-Number (Get-JsonProp $it 'custom_hitech_delivered_kg')) + (ConvertTo-Number (Get-JsonProp $it 'custom_hitech_invoiced_kg'))
        if ($rec -gt $Tolerance) {
            [void]$problems.Add(("{0} carries {1} kg from Hi-Tech here but is not on Hi-Tech's SO {2}" -f $code, (Get-RoundedHalfUp $rec 3), $num))
        }
    }
    if ($problems.Count -gt 0) {
        $out.Message = ($problems -join '; ') + ' - raise it in SAP by hand.'
        return $out
    }

    # Last: the recorded kilos against Hi-Tech's now - PASS B's own planner,
    # so the two can never disagree about what "changed" means. A refs-only
    # difference does not change what is billed and is not counted.
    $u = Get-HitechKgUpdates -SapLines $sapLines -ErpItems $erpRows -SoEntry $entry `
            -DeliveredKg $DeliveredKg -InvoicedKg $InvoicedKg -Tolerance $Tolerance
    $moved = @($u.Updates | Where-Object { $_.Fields.ContainsKey('custom_hitech_delivered_kg') -or $_.Fields.ContainsKey('custom_hitech_invoiced_kg') })
    if ($moved.Count -gt 0) {
        $out.Stale = $true
        $out.Message = ("Hi-Tech's kilos changed after they were recorded here ({0}) - check the order once the sync has recorded them, then Try again; if this repeats, raise it by hand." -f (($moved | ForEach-Object { "$($_.ItemCode) $($_.Note)" }) -join '; '))
    }
    return $out
}

function Get-MtPreSapRefusal {
    # Everything PASS C can decide before the Manna Treads login, in one
    # verdict. Pure. In this order, the first that applies:
    #   approval   - asked for by a listed approver (Test-MtApprover)
    #   shared     - no other ERPNext order on the same Hi-Tech SO
    #                (Test-MtSharedHitechOrder)
    #   duplicate  - no item on two ERPNext lines (Test-MtDuplicateLines)
    #   hitech     - Hi-Tech's own order, read this run, backs the recorded
    #                kilos (Resolve-HitechOrderFor, Get-MtHitechCheck)
    #   plan       - the rule's state, whose order it is, the customer code,
    #                the prices (Get-MtPlanRefusal)
    #   mixed      - not billed on deliveries while part was invoiced
    #                direct (Test-MtMixedBasis)
    #   allowlist  - every billed item allowed (Test-MtAllowedItems)
    # The structural ones come before the plan's state because they explain
    # it: an item Hi-Tech sent on two lines leaves the row with no kilos, and
    # the plan would call that "nothing delivered". A plan that says 'skip'
    # (not asked for, created, failed) is never overridden.
    #
    # Approval, shared and hitech are worked out by the caller (they need
    # ERPNext or Hi-Tech reads) and passed in as messages. The result names
    # the check that refused (Check) - 'hitech-stale' when the Hi-Tech check
    # only found stale kilos (-HitechStale), which Get-MtStaleVerdict may
    # turn into a transient failure.
    #
    # Computed before the Manna Treads login but ACTED ON only after the
    # NumAtCard lookup (Get-MtOrderDecision): an order a previous run created
    # is adopted whatever this says.
    param(
        [Parameter(Mandatory = $true)] $Plan,
        $Items,
        [string] $CustomerCode, [string] $HitechStatus, [string] $Unit,
        [string[]] $Allowlist,
        [string] $Approval = '',
        [string] $Shared = '',
        [string] $Hitech = '',
        [bool] $HitechStale = $false
    )
    $v = Get-MtPlanRefusal -Plan $Plan -CustomerCode $CustomerCode -HitechStatus $HitechStatus -Unit $Unit
    if ($v.Action -eq 'skip') { return @{ Action = 'skip'; Message = ''; Check = '' } }
    if ("$Approval".Trim()) { return @{ Action = 'refuse'; Message = "$Approval".Trim(); Check = 'approval' } }
    if ("$Shared".Trim())   { return @{ Action = 'refuse'; Message = "$Shared".Trim(); Check = 'shared' } }
    $dup = Test-MtDuplicateLines -Items $Items
    if ($dup) { return @{ Action = 'refuse'; Message = $dup; Check = 'duplicate' } }
    if ("$Hitech".Trim())   { return @{ Action = 'refuse'; Message = "$Hitech".Trim(); Check = $(if ($HitechStale) { 'hitech-stale' } else { 'hitech' }) } }
    if ($v.Action -ne 'create') { return @{ Action = $v.Action; Message = $v.Message; Check = 'plan' } }
    $mix = Test-MtMixedBasis -Plan $Plan -Items $Items
    if ($mix) { return @{ Action = 'refuse'; Message = $mix; Check = 'mixed' } }
    $codes = @($Plan.Lines | ForEach-Object { "$($_.Item)" })
    $na = Test-MtAllowedItems -Codes $codes -Allowlist $Allowlist
    if ($na) { return @{ Action = 'refuse'; Message = $na; Check = 'allowlist' } }
    return @{ Action = 'create'; Message = ''; Check = '' }
}

function Get-MtOrderDecision {
    # The per-order decision once the NumAtCard lookup is in. Pure.
    #
    # ADOPTION COMES FIRST. If a previous run posted the order and then failed
    # to write it back, Manna Treads SAP already bills the customer for it;
    # refusing now (Hi-Tech reopened it, a customer code changed...) would
    # leave that order unrecorded in ERPNext and invite a second one. So one
    # live order carrying the ERPNext name is adopted whatever the ERPNext
    # side says; two are refused as a duplicate; none, and the verdict worked
    # out before the login ($PreSap, Get-MtPreSapRefusal) decides.
    #
    # Action: 'adopt' (with Adopt = the SAP row), 'refuse' (with Message),
    # 'transient' (the caller marked the verdict so: nothing is written on the
    # order, it stays queued, the run fails), or 'validate' - check the
    # customer and items in Manna Treads SAP, then post.
    param([Parameter(Mandatory = $true)] $Adoptable, [Parameter(Mandatory = $true)] $PreSap)
    if ($Adoptable.Adopt) { return @{ Action = 'adopt'; Adopt = $Adoptable.Adopt; Message = '' } }
    if ("$($Adoptable.Error)".Trim() -ne '') { return @{ Action = 'refuse'; Adopt = $null; Message = "$($Adoptable.Error)" } }
    if ($PreSap.Action -eq 'transient') { return @{ Action = 'transient'; Adopt = $null; Message = "$($PreSap.Message)" } }
    if ($PreSap.Action -eq 'refuse') { return @{ Action = 'refuse'; Adopt = $null; Message = "$($PreSap.Message)" } }
    if ($PreSap.Action -eq 'create') { return @{ Action = 'validate'; Adopt = $null; Message = '' } }
    return @{ Action = 'skip'; Adopt = $null; Message = '' }
}

function Get-MtStaleVerdict {
    # What PASS C does with an order whose ONLY problem is that its recorded
    # kilos differ from Hi-Tech's now (Get-MtHitechCheck's Stale). Pure.
    #
    # If PASS B was due to refresh the order this run (it is in PASS B's open
    # or followed set) and did not - a kilo write failed, -Limit stopped it,
    # or -DryRun wrote nothing - that is the RUN's problem: 'transient',
    # nothing written on the order, retried next run. Otherwise nothing will
    # ever refresh those kilos (the order is retired and closed at Hi-Tech),
    # and it is the order's: the refusal stands, for a human.
    param([Parameter(Mandatory = $true)] $PreSap, [bool] $InPassB)
    if ($PreSap.Action -eq 'refuse' -and "$($PreSap.Check)" -eq 'hitech-stale' -and $InPassB) {
        return @{ Action = 'transient'; Message = "$($PreSap.Message)"; Check = 'hitech-stale' }
    }
    return $PreSap
}

function Test-MtQueued {
    # Whether PASS C takes an order: asked for, no Manna Treads order yet, and
    # NO error recorded - the fixture's 'queued'. An order with an error is
    # 'failed': it waits for the accountant's Try again (manna_mt_so_request,
    # which clears the error) and is not retried by every run, so one bad
    # order cannot keep failing the sync for everyone. Works on a list row or
    # a full re-read, as long as the three fields were read.
    param($Row)
    if ($null -eq $Row) { return $false }
    if (-not (ConvertTo-FlagBool (Get-JsonProp $Row 'custom_mt_so_requested'))) { return $false }
    if ((ConvertTo-CleanText (Get-JsonProp $Row 'custom_mt_sales_order')) -ne '') { return $false }
    if ((ConvertTo-CleanText (Get-JsonProp $Row 'custom_mt_sync_error')) -ne '') { return $false }
    return $true
}

function Get-MtPostFailure {
    # How a failed POST /Orders to Manna Treads is treated. Pure.
    #
    #   'refusal'   - SAP answered 4xx with its own error body: it read the
    #                 document and refused it (a price, a tax code, a
    #                 back-date rule...). That is about this order; the reason
    #                 goes on it and the run is not failed.
    #   'transient' - anything else: no response, a timeout, a 5xx, the
    #                 empty-body 500, an expired session (401), a licence
    #                 or permission answer (403, 407, 408, 429). Nothing is
    #                 written on the order, it stays queued, and the run fails
    #                 so somebody looks. If the order WAS created after all,
    #                 the next run adopts it by NumAtCard.
    param($Status, [string] $Body)
    $out = @{ Kind = 'transient'; Message = '' }
    $code = 0
    if ($null -ne $Status -and "$Status".Trim() -ne '') { $code = [int]"$Status" }
    if ($code -lt 400 -or $code -ge 500 -or $code -in @(401, 403, 407, 408, 429)) { return $out }
    if ("$Body".Trim() -eq '') { return $out }
    $text = ''
    try {
        $j = $Body | ConvertFrom-Json
        $err = Get-JsonProp $j 'error'
        if ($err) {
            $m = Get-JsonProp $err 'message'
            $v = Get-JsonProp $m 'value'
            if ("$v".Trim() -ne '') { $text = "$v" } elseif ($m -is [string]) { $text = $m }
            $c = Get-JsonProp $err 'code'
            if ($text -and $null -ne $c) { $text = "$text (SAP code $c)" }
        }
    } catch { $text = '' }
    if ("$text".Trim() -eq '') { return $out }
    $out.Kind = 'refusal'
    $out.Message = "Manna Treads SAP refused the order: $text"
    return $out
}

function Limit-MtMessage {
    # custom_mt_sync_error is read by the accountant: one line, at most
    # $Max characters.
    param([string] $Text, [int] $Max = 250)
    $s = ("$Text" -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 3) + '...' }
    return $s
}

function Enter-MtPassLock {
    # A named system mutex around PASS C, so two runs at once cannot both miss
    # on NumAtCard and both post. $null when another run holds it - the
    # caller skips PASS C this run. A mutex whose last holder died without
    # releasing it is ours (AbandonedMutexException). One created by another
    # account that this one may not open is somebody else's live run too.
    param([string] $Name = 'Global\MannaSapOrderSyncPassC')
    # PowerShell wraps a .NET exception thrown by a constructor or method, so
    # the type is looked for along the InnerException chain.
    function Test-ExceptionIs { param($Err, [string] $TypeName)
        $e = $Err.Exception
        while ($null -ne $e) { if ($e.GetType().FullName -eq $TypeName) { return $true }; $e = $e.InnerException }
        return $false
    }
    $m = $null
    try { $m = New-Object System.Threading.Mutex($false, $Name) }
    catch {
        if (Test-ExceptionIs $_ 'System.UnauthorizedAccessException') { return $null }
        throw
    }
    $got = $false
    try { $got = $m.WaitOne(0) }
    catch {
        if (Test-ExceptionIs $_ 'System.Threading.AbandonedMutexException') { $got = $true }
        else { $m.Dispose(); throw }
    }
    if (-not $got) { $m.Dispose(); return $null }
    return $m
}

function Exit-MtPassLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }
    try { $Lock.Dispose() } catch { }
}

function Write-MtRefusal {
    # A refusal about the ORDER (Get-MtPlanRefusal and the rest): the reason
    # and the time go on it, custom_mt_so_requested stays 1, so it reads
    # 'failed' with Try again on the accountant's screen - and the run is not
    # failed. Returns $false only when that write itself failed, which IS a
    # run failure (the order stays queued and is refused again next run).
    param([string] $Name, [string] $Message, [string] $When, [bool] $IsDryRun)
    $msg = Limit-MtMessage $Message 250
    $script:Result.mtRefused++
    Write-Log WARN ("PASS C {0}: not created - {1}" -f $Name, $msg)
    if ($IsDryRun) {
        Write-Log INFO ("PASS C {0}: WOULD write {1}='{2}', {3}" -f $Name, $script:F_MT_ERR, $msg, $script:F_MT_SYNCED)
        return $true
    }
    try {
        Update-ErpSalesOrder -Name $Name -Fields @{ $script:F_MT_ERR = $msg; $script:F_MT_SYNCED = $When }
        return $true
    } catch {
        Write-Log ERROR ("PASS C {0}: could not record the reason on the order, so it stays queued - {1}" -f $Name, "$_")
        $script:Result.writeErrors++; $script:Result.failures++
        return $false
    }
}

function Get-MtSettings {
    # The optional "manna_treads" block of config.json, with every default HERE:
    # the deployed config.json predates stage two. The defaults are what a real
    # Manna Treads order carries (read from MANNA_TREADS_LIVE on 26 Sep 2026:
    # the three latest orders, DocNum 437-439, are all Series 189, branch 1):
    # Series 189 (Kerala), branch 1, warehouse 01, tax CG+SG@18, location 2.
    # A key present as null means "leave it off and let SAP choose".
    # Throws on a config that is wrong rather than merely absent.
    #
    # GST is NOT here: 18%, rate GST-inclusive, fixed (Get-MtGstPercent). The
    # two knobs that briefly existed are refused if they disagree with that.
    param($Config)
    $b = Get-JsonProp $Config 'manna_treads'
    if ($null -eq $b) { $b = [pscustomobject]@{} }

    $states = New-Object System.Collections.ArrayList
    $sp = $b.PSObject.Properties['allowed_bill_to_states']
    if ($sp -and $null -ne $sp.Value) {
        foreach ($s in @($sp.Value)) { $t = "$s".Trim().ToUpperInvariant(); if ($t -ne '') { [void]$states.Add($t) } }
    } else { [void]$states.Add('KL') }

    # The items PASS C may put on a Manna Treads order (Test-MtAllowedItems).
    # Present as an array - even an empty one, which allows nothing - it
    # replaces the default; absent or null, the ten SYNC TEST items.
    $allow = New-Object System.Collections.ArrayList
    $ap = $b.PSObject.Properties['item_allowlist']
    if ($ap -and $null -ne $ap.Value) {
        foreach ($a in @($ap.Value)) { $t = "$a".Trim(); if ($t -ne '' -and -not $allow.Contains($t)) { [void]$allow.Add($t) } }
    } else {
        foreach ($n in 14636..14645) { [void]$allow.Add("I-$n") }
    }

    # Whose request PASS C acts on (Test-MtApprover): the ERPNext users that
    # custom_mt_so_requested_by may name. Present as an array - even an
    # empty one, which accepts nobody - it replaces the default; absent or
    # null, the accountant, the one user with custom_is_accountant = 1 (read
    # 26 Sep 2026). manna_mt_so_request also lets a System Manager ask; one
    # who does must be listed here too.
    $approvers = New-Object System.Collections.ArrayList
    $vp = $b.PSObject.Properties['approvers']
    if ($vp -and $null -ne $vp.Value) {
        foreach ($a in @($vp.Value)) { $t = "$a".Trim().ToLowerInvariant(); if ($t -ne '' -and -not $approvers.Contains($t)) { [void]$approvers.Add($t) } }
    } else {
        [void]$approvers.Add('jineesh@mannarubber.com')
    }

    $gp = $b.PSObject.Properties['gst_percent']
    if ($gp -and $null -ne $gp.Value -and "$($gp.Value)".Trim() -ne '' -and (ConvertTo-Number $gp.Value) -ne (Get-MtGstPercent)) {
        throw "config: 'manna_treads.gst_percent' is no longer read - GST is $(Get-MtGstPercent)%, fixed, as the fixture and the dashboard have it. Remove the key."
    }
    $rp = $b.PSObject.Properties['rate_includes_gst']
    if ($rp -and $null -ne $rp.Value -and "$($rp.Value)".Trim() -ne '' -and -not (Get-OptionalBool $b 'rate_includes_gst' $true)) {
        throw "config: 'manna_treads.rate_includes_gst' is no longer read - the approved rate always includes GST. Remove the key."
    }

    # Same SAP login as the Hi-Tech session unless BOTH are overridden. The
    # values are never echoed, placeholder or not.
    $user = Get-OptionalString $b 'username' ''
    $pass = Get-OptionalString $b 'password' ''
    $ph = '(?i)PUT_|REPLACE|PLACEHOLDER|CHANGE_?ME|XXXX|^<.+>$'
    if ($user -match $ph -or $pass -match $ph) { throw "config: 'manna_treads.username' or '.password' still holds a placeholder value." }
    if (($user -eq '') -ne ($pass -eq '')) { throw "config: set both 'manna_treads.username' and 'manna_treads.password', or neither (then the 'sap' login is used)." }

    return @{
        Enabled             = (Get-OptionalBool   $b 'enabled' $true)
        CompanyDb           = (Get-OptionalString $b 'company_db' 'MANNA_TREADS_LIVE')
        Warehouse           = (Get-OptionalString $b 'warehouse' '01')
        TaxCode             = (Get-OptionalString $b 'tax_code' 'CG+SG@18')
        LocationCode        = (Get-OptionalNullableInt $b 'location_code' 2)
        BplId               = (Get-OptionalNullableInt $b 'bpl_id' 1)
        Series              = (Get-OptionalNullableInt $b 'series' 189)
        AllowedBillToStates = [string[]]@($states)
        ItemAllowlist       = [string[]]@($allow)
        Approvers           = [string[]]@($approvers)
        Username            = $user
        Password            = $pass
    }
}

function Assert-MtCompanyDb {
    # PASS C bills END customers, so its session must be Manna Treads' and
    # nobody else's - above all never Hi-Tech's, which must not learn who
    # the goods are for. Checked before the login, on what the login is given.
    param([string] $CompanyDb, [string] $HitechCompanyDb)
    $db = "$CompanyDb".Trim()
    if ($db -ne 'MANNA_TREADS_LIVE') {
        throw "manna_treads.company_db must be MANNA_TREADS_LIVE (got '$db') - PASS C creates customer orders and logs in nowhere else."
    }
    if ($db -eq "$HitechCompanyDb".Trim()) {
        throw "manna_treads.company_db is the same database as sap.company.company_db ('$db') - refusing to put an end customer into it."
    }
}

<#
.SYNOPSIS
  The POST /Orders body for one Manna Treads Sales Order. Pure.

.DESCRIPTION
  To the END customer: this is Manna Treads billing its own customer - the
  opposite of PASS A, whose Hi-Tech order must never name one.

  Both dates are today by the server clock. The SAP login allows two days of
  back-dating (OUSR.U_BackDate), so an order dated when Hi-Tech finished would
  be refused a few days later. NumAtCard carries the ERPNext order name, which
  is what the next run adopts by; every real Manna Treads order leaves it
  empty (read 26 Sep 2026), so it is free for this. No SalesPersonCode: SAP
  takes the customer's own default, which is what every real order carries.

  One line per billable plan line - the plan has already left out a line with
  nothing. UnitPrice is the plan's price net of GST and TaxCode puts the GST
  back; sending the gross rate would bill the customer 18% high.

  DiscountPercent is 0 on EVERY line and on the header, as PASS A sends it on
  its lines (New-SapOrderLine). Left off, SAP's price determination fills a
  line discount from the customer's special prices or discount groups - and a
  document discount from the customer master - and applies it to the
  UnitPrice posted here, so the invoice would come out under the approved
  rate with nothing in the log to say so.
#>
function New-MtSalesOrderBody {
    param(
        [Parameter(Mandatory = $true)] $Plan,
        [Parameter(Mandatory = $true)] [string] $CardCode,
        [Parameter(Mandatory = $true)] [string] $OrderName,
        [string] $HitechSalesOrder = '',
        [Parameter(Mandatory = $true)] [string] $DocDate,
        [Parameter(Mandatory = $true)] $Settings
    )
    $refs = New-Object System.Collections.ArrayList
    foreach ($l in @($Plan.Lines)) {
        foreach ($piece in ("$($l.Refs)" -split ',')) {
            $t = $piece.Trim()
            if ($t -ne '' -and -not $refs.Contains($t)) { [void]$refs.Add($t) }
        }
    }
    $comments = "From ERPNext $OrderName - Hi-Tech SO $HitechSalesOrder"
    if ($refs.Count -gt 0) { $comments = $comments + ' - ' + ($refs -join ', ') }
    # ORDR.Comments holds 254 characters; SAP refuses the document over that.
    if ($comments.Length -gt 254) { $comments = $comments.Substring(0, 251) + '...' }

    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @($Plan.Lines)) {
        $dl = [ordered]@{
            ItemCode        = "$($l.Item)"
            Quantity        = [double]$l.Kg
            UnitPrice       = [double]$l.UnitPriceNet
            DiscountPercent = 0.0
        }
        if ("$($Settings.TaxCode)".Trim() -ne '')   { $dl.TaxCode       = "$($Settings.TaxCode)".Trim() }
        if ("$($Settings.Warehouse)".Trim() -ne '') { $dl.WarehouseCode = "$($Settings.Warehouse)".Trim() }
        if ($null -ne $Settings.LocationCode)       { $dl.LocationCode  = [int]$Settings.LocationCode }
        [void]$lines.Add($dl)
    }

    $body = [ordered]@{
        CardCode        = $CardCode
        DocDate         = $DocDate
        DocDueDate      = $DocDate
        NumAtCard       = $OrderName
        Comments        = $comments
        DiscountPercent = 0.0
    }
    if ($null -ne $Settings.BplId)  { $body.BPL_IDAssignedToInvoice = [int]$Settings.BplId }
    if ($null -ne $Settings.Series) { $body.Series = [int]$Settings.Series }
    $body.DocumentLines = $lines
    return $body
}

function Select-MtAdoptable {
    # Of the Manna Treads orders already carrying this ERPNext name in
    # NumAtCard, the one to adopt - a previous run created it and crashed
    # before writing back. A cancelled one is history, not an order. Two live
    # ones mean a duplicate already exists; adopting either would leave the
    # other billing the customer a second time, so that is refused.
    param($Hits)
    $live = New-Object System.Collections.ArrayList
    foreach ($h in @($Hits)) {
        if ($null -eq $h) { continue }
        if ("$(Get-JsonProp $h 'DocNum')".Trim() -eq '') { continue }
        if ("$(Get-JsonProp $h 'Cancelled')".Trim() -eq 'tYES') { continue }
        [void]$live.Add($h)
    }
    if ($live.Count -eq 0) { return @{ Adopt = $null; Error = '' } }
    if ($live.Count -eq 1) { return @{ Adopt = $live[0]; Error = '' } }
    $nums = ($live | ForEach-Object { "$(Get-JsonProp $_ 'DocNum')".Trim() }) -join ', '
    return @{ Adopt = $null; Error = ("Manna Treads SAP already has {0} live orders carrying this ERPNext name (DocNum {1}) - one is a duplicate. Cancel it in SAP and the next run adopts the other." -f $live.Count, $nums) }
}

function Test-MtCustomer {
    # '' when the Manna Treads customer can take this order, else why not.
    # $Rows is the BusinessPartners read by CardCode (none = not there).
    #
    # The bill-to state matters because the tax code is fixed: CG+SG@18 is
    # the INTRA-state split, and a customer billed outside Kerala owes IGST.
    # Refused rather than guessed at - a wrong tax code on a customer invoice
    # is a GST return problem, not a display one.
    #
    # And the customer must be the SAME customer: Customer.custom_bp_code is
    # typed by hand, so a mistyped code that happens to be another real
    # Manna Treads customer would bill that customer. With -CustomerName (the
    # ERPNext customer_name) the Manna Treads CardName must equal it,
    # compared as item names are (ConvertTo-MtItemNameKey). Read in the same
    # one BusinessPartners read.
    param($Rows, [string] $CardCode, [string[]] $AllowedStates, $CustomerName = $null)
    $bp = $null
    foreach ($r in @($Rows)) {
        if ($null -ne $r -and "$(Get-JsonProp $r 'CardCode')".Trim() -eq $CardCode) { $bp = $r; break }
    }
    if (-not $bp) { return "Customer code $CardCode is not in Manna Treads SAP." }
    $ct = "$(Get-JsonProp $bp 'CardType')".Trim()
    if ($ct -ne 'cCustomer') { return "$CardCode is not a customer in Manna Treads SAP (CardType $ct)." }
    if ($null -ne $CustomerName) {
        $mtName = Get-JsonProp $bp 'CardName'
        if ((ConvertTo-MtItemNameKey $CustomerName) -ne (ConvertTo-MtItemNameKey $mtName)) {
            return ("Customer code {0} is '{1}' in Manna Treads SAP but the customer here is '{2}' - not the same customer; check Customer.custom_bp_code." -f $CardCode, (ConvertTo-CleanText $mtName), (ConvertTo-CleanText $CustomerName))
        }
    }
    if ("$(Get-JsonProp $bp 'Valid')".Trim() -ne 'tYES' -or "$(Get-JsonProp $bp 'Frozen')".Trim() -ne 'tNO') {
        return "Customer $CardCode is inactive or frozen in Manna Treads SAP."
    }
    $st = "$(Get-JsonProp $bp 'BillToState')".Trim().ToUpperInvariant()
    if (@($AllowedStates) -notcontains $st) {
        $where = if ($st -eq '') { 'has no bill-to state' } else { "is billed to state $st" }
        return ("Customer {0} {1}, outside {2} - that needs IGST, not the intra-state tax code this sync uses. Raise this order by hand." -f $CardCode, $where, (@($AllowedStates) -join '/'))
    }
    return ''
}

function ConvertTo-MtItemNameKey {
    # An item name as the two companies' names are compared: trimmed, runs of
    # white space as one space, case ignored.
    param($Name)
    return ((ConvertTo-CleanText $Name) -replace '\s+', ' ').ToUpperInvariant()
}

function Test-MtItems {
    # '' when every item is a live sales item in Manna Treads SAP AND is the
    # same product there, else one message naming every item that is not.
    #
    # The same code is not always the same tread in the two companies: at
    # least one Hi-Tech code is a different product in Manna Treads SAP. So
    # the Manna Treads ItemName must equal the ERPNext line's item_name
    # (ConvertTo-MtItemNameKey on both). $Names maps item code -> that
    # item_name; an item missing from it is compared against ''. $Rows is the
    # one filtered Items read (ItemCode, ItemName, Valid, Frozen, SalesItem).
    # The allowlist (Test-MtAllowedItems) is checked before this.
    param([string[]] $Codes, $Rows, [hashtable] $Names = @{})
    $byCode = @{}
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $byCode["$(Get-JsonProp $r 'ItemCode')".Trim().ToUpperInvariant()] = $r
    }
    $missing = New-Object System.Collections.ArrayList
    $unusable = New-Object System.Collections.ArrayList
    $renamed = New-Object System.Collections.ArrayList
    foreach ($c in @($Codes)) {
        $k = "$c".Trim().ToUpperInvariant()
        if (-not $byCode.ContainsKey($k)) { [void]$missing.Add($c); continue }
        $r = $byCode[$k]
        if ("$(Get-JsonProp $r 'Valid')".Trim() -ne 'tYES' -or "$(Get-JsonProp $r 'Frozen')".Trim() -ne 'tNO' -or
            "$(Get-JsonProp $r 'SalesItem')".Trim() -ne 'tYES') { [void]$unusable.Add($c); continue }
        $erpName = ''
        if ($Names) { foreach ($nk in $Names.Keys) { if ("$nk".Trim().ToUpperInvariant() -eq $k) { $erpName = "$($Names[$nk])"; break } } }
        $mtName = "$(Get-JsonProp $r 'ItemName')"
        if ((ConvertTo-MtItemNameKey $erpName) -ne (ConvertTo-MtItemNameKey $mtName)) {
            [void]$renamed.Add(("{0} is '{1}' in ERPNext but '{2}' in Manna Treads SAP - not the same product" -f $c, (ConvertTo-CleanText $erpName), (ConvertTo-CleanText $mtName)))
        }
    }
    $parts = New-Object System.Collections.ArrayList
    if ($missing.Count -eq 1) { [void]$parts.Add("Item $($missing[0]) is not in Manna Treads SAP - no item mapping yet") }
    elseif ($missing.Count -gt 1) { [void]$parts.Add("Items $($missing -join ', ') are not in Manna Treads SAP - no item mapping yet") }
    if ($unusable.Count -eq 1) { [void]$parts.Add("Item $($unusable[0]) is inactive, frozen or not a sales item in Manna Treads SAP") }
    elseif ($unusable.Count -gt 1) { [void]$parts.Add("Items $($unusable -join ', ') are inactive, frozen or not sales items in Manna Treads SAP") }
    foreach ($x in $renamed) { [void]$parts.Add($x) }
    return ($parts -join '; ')
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
    $fixedCardCode = Get-RequiredString $os 'fixed_card_code' 'order_sync'         # 10118 - the inter-company CardCode, always (20416, the Gujarat company, until 26 Sep 2026)
    $sendUnitPrice = Get-OptionalBool   $os 'send_line_unit_price' $false          # default OFF - do not send the end-customer rate to the factory
    # SAP is the record for an approved order: the apps refuse to edit one, and
    # the manufacturing team reduce or drop a line there instead. ON by default
    # because an app that cannot edit and does not follow would just be stale.
    $reconcileLines = Get-OptionalBool  $os 'reconcile_lines_from_sap' $true
    # The warehouse each order line names. Empty = let SAP pick its default,
    # which is how every order up to 18 Sep 2026 ended up committing stock to
    # warehouse 01 while the finished goods sat in 07.
    $lineWarehouse = Get-OptionalString $os 'line_warehouse' ''
    $stampField    = Get-OptionalString $os 'stamp_erpnext_name_in' 'NumAtCard'   # NumAtCard | U_FreeText | none
    # How far back the delivery and invoice scans look. Deliveries are still
    # read - not for status, but because the line reconcile needs them.
    $deliveryDays  = Get-OptionalInt    $os 'delivery_scan_days' 120
    $invoiceDays   = Get-OptionalInt    $os 'invoice_scan_days' $deliveryDays
    # stage_source, production_scan_statuses, production_status_labels and
    # delivery_ship_date_from are no longer read (24 Sep 2026). A config that
    # still carries them is fine; they are ignored.

    if ($stampField -notin @('NumAtCard', 'U_FreeText', 'none')) {
        throw "config: order_sync.stamp_erpnext_name_in must be NumAtCard, U_FreeText or none (got '$stampField')."
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
    Write-Log INFO ("==== run start ==== company='{0}' db='{1}' DryRun={2} Limit={3} gate='{4}' cardCode={5} sendUnitPrice={6} warehouse={7} stamp={8} deliveryDays={9} invoiceDays={10} PS={11}" -f `
        $companyName, $companyDb, [bool]$DryRun, $Limit, $poGate, $fixedCardCode, $sendUnitPrice, $(if ($lineWarehouse -eq '') { "<SAP default>" } else { $lineWarehouse }), $stampField, $deliveryDays, $invoiceDays, $PSVersionTable.PSVersion)

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

        # PASS B's working set: in SAP and not yet FULLY invoiced. The
        # order-level custom_sap_invoice is written only once every line is,
        # so a partly-invoiced order stays here and its remaining lines are
        # still followed. This field must exist in ERPNext before this runs -
        # Frappe fails the whole list on an unknown field in a filter.
        $openFilter = '[["' + $script:F_SO + '","is","set"],["' + $script:F_INV + '","in",["",null]],["docstatus","<",2]]'
        $openList   = Get-ErpList -Filters $openFilter -Fields @('name', 'customer', $script:F_SO, $script:F_SO_STAT)
        $openList   = @($openList | Sort-Object { "$($_.name)" })

        $script:Result.inScopeNew = $newList.Count
        Write-Log INFO ("ERPNext: {0} order(s) approved & not yet in SAP; {1} order(s) in SAP & not yet fully invoiced." -f $newList.Count, $openList.Count)

        # PASS B (follow): a Manna Treads order PASS B has retired - every line
        # invoiced, custom_sap_invoice written - while Hi-Tech's SO is still
        # open. Nothing else would ever refresh its SAP status or its Hi-Tech
        # kilos, so a short-delivered order invoiced before Hi-Tech closed it
        # would never read bost_Close, never become 'ready', and never be
        # billed. Only the status and the three kilo fields are followed; the
        # line reconcile and invoice linking are done with it. It leaves this
        # set once Hi-Tech closes or cancels it, or its Manna Treads order
        # exists. Its own try: a failure here is this read's, not the run's.
        $followList = @()
        try {
            $followFilter = '[["custom_company","=","Manna Treads"],["' + $script:F_SO + '","is","set"],["' + $script:F_INV + '","is","set"],["' + $script:F_MT_SO + '","in",["",null]],["docstatus","<",2],["' + $script:F_SO_STAT + '","not in",["bost_Close","bost_Cancelled"]]]'
            $followList   = Get-ErpList -Filters $followFilter -Fields @('name', 'customer', $script:F_SO, $script:F_SO_STAT)
            $followList   = @($followList | Sort-Object { "$($_.name)" })
            Write-Log INFO ("ERPNext: {0} fully invoiced Manna Treads order(s) still open at Hi-Tech, followed for status and kilos." -f $followList.Count)
        } catch {
            Write-Log ERROR ("PASS B (follow): could not read its orders - skipped this run: {0}" -f "$_")
            $script:Result.failures++
            $followList = @()
        }

        # PASS C's working set: orders the accountant has approved for Manna
        # Treads that do not have their Manna Treads order yet. The SAME gate
        # as PASS A and never a wider one - 'Pending Final Approval' and
        # 'Pending GM Approval' orders must never reach either company. Read
        # here, before the nothing-to-do exit, because an order PASS B has
        # already retired (fully invoiced) is exactly the kind he approves.
        # Anything wrong here is PASS C's alone: PASS A and B still run.
        #
        # Only QUEUED orders (Test-MtQueued): asked for and no error recorded.
        # One with an error is 'failed' and waits for the accountant's Try
        # again, which clears it - so a refused order is not retried, and does
        # not fail, every run.
        $mt = $null
        $mtList = @()
        try {
            $mt = Get-MtSettings -Config $config
            if ($mt.Enabled) {
                $mtFilter = '[["' + $script:F_MT_REQ + '","=",1],["' + $script:F_MT_SO + '","in",["",null]],["' + $script:F_SO + '","is","set"],["custom_po_status","=","' + $poGate + '"],["docstatus","<",2]]'
                $mtAll    = @(Get-ErpList -Filters $mtFilter -Fields @('name', 'customer', $script:F_SO, $script:F_MT_REQ, $script:F_MT_SO, $script:F_MT_ERR))
                $mtList   = @($mtAll | Where-Object { Test-MtQueued $_ } | Sort-Object { "$($_.name)" })
                $script:Result.mtFailedWaiting = $mtAll.Count - $mtList.Count
                Write-Log INFO ("ERPNext: {0} order(s) queued for Manna Treads; {1} failed earlier and wait for the accountant's Try again." -f $mtList.Count, $script:Result.mtFailedWaiting)
            } else {
                Write-Log INFO "PASS C (Manna Treads sales orders) is disabled in config (manna_treads.enabled = false)."
            }
        } catch {
            Write-Log ERROR ("PASS C: could not read its settings or its orders - skipped this run: {0}" -f "$_")
            $script:Result.failures++
            $mtList = @()
        }
        $script:Result.mtRequested = $mtList.Count

        # The orders PASS B is due to refresh this run - its open and
        # followed sets. PASS C treats stale kilos on one of these as the
        # run's problem, not the order's (Get-MtStaleVerdict).
        $passBNames = @{}
        foreach ($r in @(@($openList) + @($followList))) { if ($null -ne $r) { $passBNames["$($r.name)"] = $true } }

        # (A PASS C read failure is not "nothing to do": it falls through to the
        # summary so the run exits non-zero. Nothing logs in with empty lists.)
        if ($newList.Count -eq 0 -and $openList.Count -eq 0 -and $followList.Count -eq 0 -and $mtList.Count -eq 0 -and $script:Result.failures -eq 0) {
            Write-Log INFO "nothing to do."
            $script:Result.summary = "SUMMARY | company: $companyName | nothing to do (0 new, 0 open, 0 followed, 0 queued for Manna Treads)"
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
            # Also when only PASS C has work: before it bills an order it checks
            # Hi-Tech's own order, read here, against the kilos recorded
            # (Get-MtHitechCheck). Still one seat at a time - this session is
            # logged out before PASS C logs in to Manna Treads.
            if ($newList.Count -gt 0 -or $openList.Count -gt 0 -or $followList.Count -gt 0 -or $mtList.Count -gt 0) {
                $sess = New-SapWebSession -BaseUrl $sapUrl -Username $sapUser -Password $sapPass `
                    -CompanyDb $companyDb -CompanyName $companyName -UseSkipCert $useSkip
            }

            # ---- 2a. the rep -> sales employee map (PASS A only) ----
            # One small GET; SAP has a couple of dozen sales employees. Skipped
            # entirely when there is nothing to create.
            $salesPersonMap = @{}
            if ($newList.Count -gt 0) {
                $salesPersonMap = Get-SapSalesPersonMap -BaseUrl $sapUrl -Session $sess -PageSize $pageSize -UseSkipCert $useSkip
                Write-Log INFO ("SAP: {0} active sales employee(s) can be tagged on an order." -f $salesPersonMap.Count)
            }

            # ---- 2b. prefetch scans for PASS B (only if needed) ----
            $dnByEntryItem  = @{}   # "SO DocEntry|ItemCode" -> the delivery that carried THAT line (reconcile only)
            $dnLineToSo     = @{}   # "DN DocEntry|DN LineNum" -> SO DocEntry, to follow an invoice back through its delivery
            $invByEntryItem = @{}   # "SO DocEntry|ItemCode" -> the A/R invoice that carried THAT line
            # Stage two: per SO LINE ("SO DocEntry|SO LineNum"), what Hi-Tech sent.
            $dnKgByLine   = @{}     # -> kilos on live deliveries drawn from that line
            $dnRefsByLine = @{}     # -> "DN <DocNum> (<dd-mm-yyyy>)" of each of them
            $invKgByLine  = @{}     # -> kilos on live invoices drawn STRAIGHT from it (BaseType 17)
            $dnCancelledSkipped = 0
            $sapOrderByDocNum = @{}
            $cutoff = ''; $invCutoff = ''
            $hitechRead = $false    # PASS C checks Hi-Tech's orders only if this ran
            if ($openList.Count -gt 0 -or $followList.Count -gt 0 -or $mtList.Count -gt 0) {
                # SAP Orders for the open set, the followed one and PASS C's
                # queued one, resolved by DocNum (need DocEntry to join).
                $docNums = @(@($openList) + @($followList) + @($mtList) | ForEach-Object { "$(Get-JsonProp $_ $script:F_SO)".Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
                $chunk = 40
                for ($i = 0; $i -lt $docNums.Count; $i += $chunk) {
                    $slice = $docNums[$i..([math]::Min($i + $chunk - 1, $docNums.Count - 1))]
                    $ors = ($slice | ForEach-Object { "DocNum eq $_" }) -join ' or '
                    # DocumentLines is here for the line reconcile: SAP is the
                    # record for an approved order, so PASS B has to see what
                    # its lines say now, not just the order's status. DocDate
                    # tells the stage-two kilos whether the delivery and
                    # invoice scans reach back far enough to see all of it.
                    $rel = "Orders?`$filter=$([uri]::EscapeDataString($ors))&`$select=DocEntry,DocNum,DocDate,DocumentStatus,Cancelled,NumAtCard,DocumentLines"
                    foreach ($o in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $rel -PageSize $pageSize -UseSkipCert $useSkip -Label "Orders by DocNum")) {
                        $dn = "$(Get-JsonProp $o 'DocNum')"
                        # ArrayList, not Generic.List[object]: @() over a generic list
                        # throws "Argument types do not match" on this PS 5.1 build
                        # (same reason DocumentLines uses ArrayList).
                        if (-not $sapOrderByDocNum.ContainsKey($dn)) { $sapOrderByDocNum[$dn] = New-Object System.Collections.ArrayList }
                        [void]$sapOrderByDocNum[$dn].Add($o)
                    }
                }

                # Recent deliveries + their base-document links.
                #
                # NOT for status - a delivery is not dispatch in this release.
                # Two other jobs need it:
                #   - the line reconcile, which tells a shipped closed line from
                #     a dropped one by whether it was delivered (or invoiced);
                #   - following an invoice back to its sales order, when the
                #     invoice was raised from the delivery rather than the order.
                $cutoff = (Get-Date).AddDays(-1 * [math]::Abs($deliveryDays)).ToString('yyyy-MM-dd')
                $dnRel = "DeliveryNotes?`$filter=DocDate ge $cutoff&`$select=DocEntry,DocNum,DocDate,Cancelled,CancelStatus,DocumentLines&`$orderby=DocDate"
                $dnRel = $dnRel -replace ' ', '%20'
                foreach ($dn in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $dnRel -PageSize $pageSize -UseSkipCert $useSkip -Label "recent DeliveryNotes")) {
                    # A cancelled delivery and its reversal are not deliveries,
                    # for the reconcile either (Test-SapDocumentCounts, 26 Sep 2026).
                    if (-not (Test-SapDocumentCounts $dn)) { $dnCancelledSkipped++; continue }
                    $null = Add-HitechDeliveredKg -DeliveryNote $dn -KgByLine $dnKgByLine -RefsByLine $dnRefsByLine
                    $dnEntry = "$(Get-JsonProp $dn 'DocEntry')".Trim()
                    foreach ($dl in @(Get-JsonProp $dn 'DocumentLines')) {
                        if ([int](ConvertTo-Number (Get-JsonProp $dl 'BaseType')) -ne $SAP_BASETYPE_SALESORDER) { continue }
                        $be = "$(Get-JsonProp $dl 'BaseEntry')".Trim()
                        if ($be -eq '') { continue }
                        # Per LINE. A delivery need not carry the whole order.
                        $di = "$(Get-JsonProp $dl 'ItemCode')".Trim()
                        if ($di -ne '' -and -not $dnByEntryItem.ContainsKey("$be|$di")) {
                            $dnByEntryItem["$be|$di"] = $dn
                        }
                        $dln = "$(Get-JsonProp $dl 'LineNum')".Trim()
                        if ($dnEntry -ne '' -and $dln -ne '') { $dnLineToSo["$dnEntry|$dln"] = $be }
                    }
                }

                # Recent A/R invoices - the only thing that makes a line Dispatched.
                #
                # Resolved per LINE: a pooled invoice can carry lines from several
                # sales orders, and a line may be based on the order or on a
                # delivery (Resolve-InvoiceLineSoEntry). A cancelled invoice is not
                # a dispatch and is skipped - otherwise cancelling a wrong invoice
                # in SAP would leave the order reading Dispatched for ever.
                $invCutoff = (Get-Date).AddDays(-1 * [math]::Abs($invoiceDays)).ToString('yyyy-MM-dd')
                $invRel = "Invoices?`$filter=DocDate ge $invCutoff&`$select=DocEntry,DocNum,DocDate,Cancelled,DocumentLines&`$orderby=DocDate"
                $invRel = $invRel -replace ' ', '%20'
                $invCancelledSkipped = 0
                foreach ($inv in (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl $invRel -PageSize $pageSize -UseSkipCert $useSkip -Label "recent Invoices")) {
                    if ("$(Get-JsonProp $inv 'Cancelled')" -eq 'tYES') { $invCancelledSkipped++; continue }
                    $null = Add-HitechInvoicedKg -Invoice $inv -KgByLine $invKgByLine
                    foreach ($il in @(Get-JsonProp $inv 'DocumentLines')) {
                        $soE = Resolve-InvoiceLineSoEntry -InvoiceLine $il -DnLineToSo $dnLineToSo
                        if ($soE -eq '') {
                            if ([int](ConvertTo-Number (Get-JsonProp $il 'BaseType')) -eq 15) { $script:Result.invoiceUnresolved++ }
                            continue
                        }
                        $ii = "$(Get-JsonProp $il 'ItemCode')".Trim()
                        # Earliest invoice wins (orderby asc): the line went on that one.
                        if ($ii -ne '' -and -not $invByEntryItem.ContainsKey("$soE|$ii")) {
                            $invByEntryItem["$soE|$ii"] = $inv
                        }
                    }
                }
                Write-Log INFO ("SAP prefetch: {0} SAP order(s) resolved, {1} delivered line link(s), {2} invoiced line link(s); {3} cancelled invoice(s) ignored; {4} invoice line(s) based on a delivery older than the scan window." -f `
                    ($sapOrderByDocNum.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum, $dnByEntryItem.Count, $invByEntryItem.Count, $invCancelledSkipped, $script:Result.invoiceUnresolved)
                Write-Log INFO ("SAP prefetch (stage two): {0} SO line(s) with delivered kilos, {1} with kilos invoiced straight from the order; {2} cancelled or reversal delivery note(s) ignored." -f `
                    $dnKgByLine.Count, $invKgByLine.Count, $dnCancelledSkipped)
                $hitechRead = $true
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

                    # CardCode is ALWAYS the fixed inter-company code (10118). No
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

            # =================== PASS B - pull status / lines / invoices ===================
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

                    $fields[$script:F_ERR] = ''   # clean pass clears a stale error

                    # Per-line invoice. The join is the item code, as the delivery
                    # join always was: an ERPNext row does not carry its SAP line
                    # number. An item appearing on two lines of one order would be
                    # ambiguous; both lines then get the same invoice, which is the
                    # honest answer when SAP cannot be asked which line it meant.
                    $lineUpdates = New-Object System.Collections.ArrayList
                    $lineInvoices = New-Object System.Collections.ArrayList   # one per ERPNext line; $null = not invoiced
                    $kgUpdates = New-Object System.Collections.ArrayList      # stage-two kilos, per line
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
                            # Which items a delivery OR an invoice actually carried
                            # for THIS order. A SAP line closes both when it ships
                            # and when the factory drops it, and nothing on the
                            # line itself tells the two apart - see
                            # Get-ErpLineCorrections. Invoices count too: a line
                            # invoiced straight from the order has no delivery,
                            # and leaving it out would delete a billed line.
                            $delivered = @{}
                            foreach ($map in @($dnByEntryItem, $invByEntryItem)) {
                                foreach ($dk in $map.Keys) {
                                    $bits = "$dk".Split('|', 2)
                                    if ($bits.Count -eq 2 -and $bits[0] -eq $soEntry) { $delivered[$bits[1]] = $true }
                                }
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

                        # ---- stage two: what Hi-Tech actually delivered and invoiced ----
                        #
                        # After the reconcile, on the rows it left. The accountant
                        # bills the end customer from these figures, not from the
                        # ordered kilos: the reconcile leaves a short-delivered
                        # closed line at what was ORDERED, and billing that would
                        # overbill every short delivery. Rule and reasons:
                        # shared/fixtures/manna_treads_reorder.json.
                        #
                        # Not when Hi-Tech's order names ANOTHER ERPNext order
                        # in NumAtCard (Get-HitechOwnerNote): matched by DocNum
                        # alone, a Desk copy of a finished order would be given
                        # the original's kilos and billed a second time.
                        $owner = Get-HitechOwnerNote -SapOrder $sapOrder -OrderName $name
                        if ($owner) {
                            Write-Log WARN ("PASS B {0}: Hi-Tech kilos not written - {1}; they are that order's." -f $name, $owner)
                        } else {
                            $soDate = ConvertTo-DateOnly (Get-JsonProp $sapOrder 'DocDate')
                            $kgPlan = Get-HitechKgUpdates `
                                -SapLines @(Get-JsonProp $sapOrder 'DocumentLines') `
                                -ErpItems @(Get-JsonProp $full 'items') `
                                -SoEntry $soEntry `
                                -DeliveredKg $dnKgByLine -InvoicedKg $invKgByLine -DeliveryRefs $dnRefsByLine `
                                -DeliveryScanComplete ([bool]($soDate -and $soDate -ge $cutoff)) `
                                -InvoiceScanComplete ([bool]($soDate -and $soDate -ge $invCutoff))
                            foreach ($ks in $kgPlan.Skips) {
                                Write-Log WARN ("PASS B {0}: Hi-Tech kilos for line {1} not written - {2}" -f $name, $ks.ItemCode, $ks.Note)
                            }
                            $kgUpdates = $kgPlan.Updates
                        }

                        foreach ($row in @(Get-JsonProp $full 'items')) {
                            $ic = "$(Get-JsonProp $row 'item_code')".Trim()
                            $rn = "$(Get-JsonProp $row 'name')".Trim()
                            if (-not $ic -or -not $rn) { continue }
                            $key = "$soEntry|$ic"

                            $hadNo = "$(Get-JsonProp $row $script:F_INV)".Trim()
                            if ($hadNo -eq 'null') { $hadNo = '' }
                            $hadDt = "$(Get-JsonProp $row $script:F_INV_DT)".Trim()
                            if ($hadDt -eq 'null') { $hadDt = '' }

                            # The invoice that carried THIS line, if any. A line
                            # left off a partial invoice keeps these blank and so
                            # never reads Dispatched, while its neighbours do.
                            if ($invByEntryItem.ContainsKey($key)) {
                                $linv  = $invByEntryItem[$key]
                                [void]$lineInvoices.Add($linv)
                                $invNo = "$(Get-JsonProp $linv 'DocNum')"
                                $invDt = ConvertTo-DateOnly (Get-JsonProp $linv 'DocDate')
                                # Only when it changes: this runs every pass for
                                # every open order, and an unchanged write still
                                # bumps `modified` on the row.
                                if ($hadNo -eq $invNo -and (-not $invDt -or $hadDt -eq "$invDt")) { continue }
                                $lf = @{ $script:F_INV = $invNo }
                                if ($invDt) { $lf[$script:F_INV_DT] = $invDt }
                                [void]$lineUpdates.Add([pscustomobject]@{ RowName = $rn; ItemCode = $ic; Fields = $lf })
                                $script:Result.linesInvoiced++
                            }
                            elseif ($hadNo) {
                                # Recorded as invoiced, but no live invoice for it
                                # this run: either the invoice has since been
                                # cancelled, or it is older than the scan window.
                                # Those need opposite answers and this run cannot
                                # tell them apart, so it is left as it is and said
                                # out loud rather than guessed at. It still counts
                                # towards the order being complete.
                                Write-Log WARN ("PASS B {0}: line {1} shows invoice {2} but no live invoice for it was found in the last {3} day(s) - cancelled since, or older than the scan. Left as it is." -f `
                                    $name, $ic, $hadNo, $invoiceDays)
                                [void]$lineInvoices.Add([pscustomobject]@{ DocNum = $hadNo; DocDate = $hadDt; DocEntry = 0 })
                            }
                            else {
                                [void]$lineInvoices.Add($null)
                            }
                        }

                        # ORDER level - only once EVERY line has been invoiced.
                        #
                        # This field is what takes an order out of PASS B: the
                        # scan reads orders where it is still empty. Writing it
                        # for a partial invoice would retire an order that still
                        # owes the customer a line, and nothing would ever poll it
                        # again - the trap the old order-level delivery had, seen
                        # on SAP order 381 where three lines shipped and one
                        # stayed open.
                        $lineCount = $lineInvoices.Count
                        $invoiced  = @($lineInvoices | Where-Object { $null -ne $_ })
                        if ($lineCount -gt 0 -and $invoiced.Count -eq $lineCount) {
                            $done = Select-CompletingInvoice $invoiced
                            $fields[$script:F_INV] = "$(Get-JsonProp $done 'DocNum')"
                            $odt = ConvertTo-DateOnly (Get-JsonProp $done 'DocDate')
                            if ($odt) { $fields[$script:F_INV_DT] = $odt }
                            $script:Result.ordersInvoiced++
                            Write-Log INFO ("PASS B {0}: every line invoiced - completed by invoice {1}; the order leaves PASS B." -f $name, $fields[$script:F_INV])
                        }
                        elseif ($invoiced.Count -gt 0) {
                            Write-Log INFO ("PASS B {0}: invoiced in part ({1} of {2} line(s)) - stays in scope." -f $name, $invoiced.Count, $lineCount)
                        }
                    }

                    if ($DryRun) {
                        Write-Log INFO ("PASS B {0}: WOULD write {1}" -f $name, (($fields.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
                        foreach ($lu in $lineUpdates) {
                            Write-Log INFO ("PASS B {0}:   line {1} WOULD get {2}" -f $name, $lu.ItemCode, (($lu.Fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
                        }
                        foreach ($ku in $kgUpdates) {
                            Write-Log INFO ("PASS B {0}:   line {1} WOULD get Hi-Tech kilos {2} ({3})" -f $name, $ku.ItemCode, (($ku.Fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '), $ku.Note)
                        }
                    } else {
                        # The Hi-Tech kilos go in FIRST - the accountant bills
                        # from them - then the header, then the line invoices.
                        # If any kilo write fails, the header holds back what
                        # would move the order on as though they had gone in
                        # (Limit-PassBHeaderOnKgFailure): the SAP status, so an
                        # order Hi-Tech has just closed does not read 'ready'
                        # on stale kilos, and the order-level invoice, which
                        # would RETIRE it before they were written. The next
                        # run writes them all again.
                        $kgFailed = Write-HitechKgUpdates -Name $name -Updates $kgUpdates -Label 'PASS B'
                        $held = Limit-PassBHeaderOnKgFailure -Fields $fields -KgFailed $kgFailed   # an ArrayList, never wrapped
                        if ($held -contains $script:F_INV) {
                            $script:Result.ordersInvoiced--
                            Write-Log WARN ("PASS B {0}: NOT retired this run - {1} Hi-Tech kilo write(s) failed; it stays in PASS B so they are written again." -f $name, $kgFailed)
                        }
                        if ($held -contains $script:F_SO_STAT) {
                            Write-Log WARN ("PASS B {0}: SAP status not written this run - {1} Hi-Tech kilo write(s) failed; the next run writes both." -f $name, $kgFailed)
                        }
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

            # =========== PASS B (follow) - retired, still open at Hi-Tech ===========
            #
            # SAP status and the three Hi-Tech kilo fields ONLY (and the
            # synced-at stamp): the line reconcile and the invoice linking
            # finished with the order when PASS B retired it. Kilos first; if
            # any of them fails, the status is held back this run, so an order
            # Hi-Tech has just closed does not leave this set - and reach the
            # accountant - on stale kilos.
            $doneF = 0
            foreach ($row in $followList) {
                if ($Limit -gt 0 -and $doneF -ge $Limit) { Write-Log WARN ("PASS B (follow) -Limit {0} reached; {1} order(s) left for the next run." -f $Limit, ($followList.Count - $doneF)); break }
                $name  = "$($row.name)"
                $soNum = "$(Get-JsonProp $row $script:F_SO)".Trim()
                $doneF++
                try {
                    $sapOrder = $null
                    if ($sapOrderByDocNum.ContainsKey($soNum)) {
                        $cands = $sapOrderByDocNum[$soNum]   # ArrayList - do NOT wrap in @() on this build
                        if ($cands.Count -eq 1) { $sapOrder = $cands[0] }
                        else { foreach ($c in $cands) { if ("$(Get-JsonProp $c 'NumAtCard')" -eq $name) { $sapOrder = $c; break } } }
                    }
                    if (-not $sapOrder) { Write-Log WARN ("PASS B (follow) {0}: SAP Order DocNum {1} not found, or not told apart from another by NumAtCard - skipped this pass." -f $name, $soNum); continue }

                    $soEntry = "$(Get-JsonProp $sapOrder 'DocEntry')".Trim()
                    $status  = Resolve-SoStatus $sapOrder
                    $full    = Get-ErpSalesOrder -Name $name
                    $soDate  = ConvertTo-DateOnly (Get-JsonProp $sapOrder 'DocDate')
                    $owner   = Get-HitechOwnerNote -SapOrder $sapOrder -OrderName $name
                    if ($owner) {
                        # Another order's Hi-Tech SO (see PASS B): its kilos are not this one's.
                        Write-Log WARN ("PASS B (follow) {0}: Hi-Tech kilos not written - {1}; they are that order's." -f $name, $owner)
                        $kgPlan = @{ Updates = (New-Object System.Collections.ArrayList); Skips = (New-Object System.Collections.ArrayList) }
                    } else {
                        $kgPlan = Get-HitechKgUpdates `
                            -SapLines @(Get-JsonProp $sapOrder 'DocumentLines') `
                            -ErpItems @(Get-JsonProp $full 'items') `
                            -SoEntry $soEntry `
                            -DeliveredKg $dnKgByLine -InvoicedKg $invKgByLine -DeliveryRefs $dnRefsByLine `
                            -DeliveryScanComplete ([bool]($soDate -and $soDate -ge $cutoff)) `
                            -InvoiceScanComplete ([bool]($soDate -and $soDate -ge $invCutoff))
                    }
                    foreach ($ks in $kgPlan.Skips) {
                        Write-Log WARN ("PASS B (follow) {0}: Hi-Tech kilos for line {1} not written - {2}" -f $name, $ks.ItemCode, $ks.Note)
                    }
                    $oldStatus = ConvertTo-CleanText (Get-JsonProp $full $script:F_SO_STAT)
                    $fields = @{ $script:F_SYNCED = $nowStr }

                    if ($DryRun) {
                        Write-Log INFO ("PASS B (follow) {0}: WOULD write {1}={2} (was '{3}')" -f $name, $script:F_SO_STAT, $status, $oldStatus)
                        foreach ($ku in $kgPlan.Updates) {
                            Write-Log INFO ("PASS B (follow) {0}:   line {1} WOULD get Hi-Tech kilos {2} ({3})" -f $name, $ku.ItemCode, (($ku.Fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '), $ku.Note)
                        }
                    } else {
                        $kgFailed = Write-HitechKgUpdates -Name $name -Updates $kgPlan.Updates -Label 'PASS B (follow)'
                        if ($kgFailed -gt 0) {
                            Write-Log WARN ("PASS B (follow) {0}: SAP status not written this run - {1} Hi-Tech kilo write(s) failed; the next run writes both." -f $name, $kgFailed)
                        } else {
                            $fields[$script:F_SO_STAT] = $status
                        }
                        Update-ErpSalesOrder -Name $name -Fields $fields
                        if ($fields.ContainsKey($script:F_SO_STAT) -and $status -ne $oldStatus) {
                            Write-Log INFO ("PASS B (follow) {0}: Hi-Tech status {1} -> {2}." -f $name, $(if ($oldStatus) { $oldStatus } else { '<none>' }), $status)
                        }
                        if (($fields.ContainsKey($script:F_SO_STAT) -and $status -ne $oldStatus) -or $kgPlan.Updates.Count -gt 0) { $script:Result.changed++ }
                    }
                    $script:Result.followPolled++
                } catch {
                    # Nothing is written on the order: its error field is PASS
                    # A/B's, and this set only refreshes figures.
                    Write-Log ERROR ("PASS B (follow) {0}: FAILED - {1}" -f $name, "$_")
                    $script:Result.failures++
                }
            }
        }
        finally {
            Invoke-SapLogout -BaseUrl $sapUrl -Session $sess -UseSkipCert $useSkip
        }

        # =================== PASS C - Manna Treads sales orders ===================
        #
        # Stage two (26 Sep 2026). A finished Hi-Tech order the accountant has
        # approved is re-created in MANNA_TREADS_LIVE as a Sales Order to the
        # END customer, billing what Hi-Tech actually sent. Its own session,
        # opened only when an order is queued and after Hi-Tech's has been
        # logged out, so the run never holds two of the five seats.
        #
        # ONE RUN AT A TIME. A named system mutex (Enter-MtPassLock) is held
        # around the whole pass: two runs at once could both miss on
        # NumAtCard and both post. If another run holds it, PASS C is skipped
        # with a WARN and its orders stay queued. -DryRun posts nothing and
        # does not take it.
        #
        # Two halves. First, before the Manna Treads login, each queued order
        # is re-read and planned, and what would refuse it is worked out
        # (Get-MtPreSapRefusal) - but NOT acted on yet: who asked for it, any
        # other ERPNext order on the same Hi-Tech SO, and Hi-Tech's own order
        # as the Hi-Tech session read it this run against the kilos recorded
        # (Get-MtHitechCheck). Then one Manna Treads login, and per order the
        # NumAtCard lookup comes BEFORE any refusal (Get-MtOrderDecision): an
        # order a previous run posted but never recorded is adopted whatever
        # else is true.
        #
        # What counts as what (26 Sep 2026):
        #   refusal   - about the order: written on it (custom_mt_sync_error,
        #               custom_mt_synced_at; custom_mt_so_requested stays 1),
        #               counted as 'mt refused', and NOT a run failure. It
        #               waits for the accountant's Try again.
        #   transient - a network, login, SAP 5xx or ERPNext read/write
        #               failure: nothing written on the order, it stays
        #               queued for the next run, and the run fails.
        if ($mtList.Count -gt 0) {
            $mtLock = $null
            $mtGo = $false
            if ($DryRun) {
                Write-Log INFO "PASS C: -DryRun posts nothing, so it does not take the PASS C lock."
                $mtGo = $true
            } else {
                try {
                    $mtLock = Enter-MtPassLock
                    if ($null -eq $mtLock) {
                        Write-Log WARN ("PASS C: another sync run holds the PASS C lock - skipped this run; the {0} queued order(s) stay queued for the next one." -f $mtList.Count)
                    } else { $mtGo = $true }
                } catch {
                    Write-Log ERROR ("PASS C: could not take the PASS C lock - skipped this run: {0}" -f "$_")
                    $script:Result.failures++
                }
            }

            if ($mtGo) {
              try {
                $mtNow   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                $mtToday = (Get-Date).ToString('yyyy-MM-dd')
                Write-Log INFO ("PASS C settings: db={0} series={1} branch={2} warehouse={3} tax={4} location={5} gst={6}% (fixed, rate includes it) billToStates={7} items={8} approvers={10} login={9}" -f `
                    $mt.CompanyDb, $(if ($null -eq $mt.Series) { '<SAP default>' } else { $mt.Series }),
                    $(if ($null -eq $mt.BplId) { '<omit>' } else { $mt.BplId }), $mt.Warehouse, $mt.TaxCode,
                    $(if ($null -eq $mt.LocationCode) { '<omit>' } else { $mt.LocationCode }),
                    (Get-MtGstPercent), ($mt.AllowedBillToStates -join '/'), ($mt.ItemAllowlist -join ','),
                    $(if ($mt.Username) { 'manna_treads' } else { 'sap' }),
                    $(if (@($mt.Approvers).Count -eq 0) { '<nobody>' } else { $mt.Approvers -join ',' }))

                # ---- 1. ERPNext only: re-read, plan, and work out any refusal ----
                $bpByCustomer = @{}
                $mtWork = New-Object System.Collections.ArrayList
                $doneC = 0
                foreach ($row in $mtList) {
                    if ($Limit -gt 0 -and $doneC -ge $Limit) { Write-Log WARN ("PASS C -Limit {0} reached; {1} order(s) left for the next run." -f $Limit, ($mtList.Count - $doneC)); break }
                    $name = "$($row.name)"
                    $doneC++
                    try {
                        # fresh re-read - the list is minutes old by now
                        $doc = Get-ErpSalesOrder -Name $name
                        $hasMt = ConvertTo-CleanText (Get-JsonProp $doc $script:F_MT_SO)
                        if ($hasMt -ne '') { Write-Log INFO ("PASS C {0}: already has Manna Treads order {1} - skipping (no double create)." -f $name, $hasMt); continue }
                        if (-not (ConvertTo-FlagBool (Get-JsonProp $doc $script:F_MT_REQ))) { Write-Log WARN ("PASS C {0}: no longer asked for - skipping." -f $name); continue }
                        if (-not (Test-MtQueued $doc)) { Write-Log INFO ("PASS C {0}: an error was recorded on it since the list was read - it waits for Try again." -f $name); continue }
                        if ([int](ConvertTo-Number (Get-JsonProp $doc 'docstatus')) -eq 2) { Write-Log WARN ("PASS C {0}: order is cancelled (docstatus 2) - skipping." -f $name); continue }
                        if ("$(Get-JsonProp $doc 'custom_po_status')" -ne $poGate) { Write-Log WARN ("PASS C {0}: custom_po_status is no longer '{1}' - skipping." -f $name, $poGate); continue }

                        $cust = ConvertTo-CleanText (Get-JsonProp $doc 'customer')
                        if (-not $bpByCustomer.ContainsKey($cust)) {
                            $bpByCustomer[$cust] = $(if ($cust -eq '') { @{ Code = ''; Name = '' } } else { Get-ErpCustomerForMt -Name $cust })
                        }
                        $bpCode   = $bpByCustomer[$cust].Code
                        $custName = $bpByCustomer[$cust].Name
                        if ($custName -eq '') { $custName = ConvertTo-CleanText (Get-JsonProp $doc 'customer_name') }
                        $items    = @(Get-JsonProp $doc 'items')
                        $hitechSo = ConvertTo-CleanText (Get-JsonProp $doc $script:F_SO)

                        $plan = Get-MtReorderPlan -Order (ConvertTo-MtReorderInput -Doc $doc -BpCode $bpCode)

                        # Who asked for it (Test-MtApprover).
                        $approval = Test-MtApprover -RequestedBy (ConvertTo-CleanText (Get-JsonProp $doc $script:F_MT_REQ_BY)) -Approvers $mt.Approvers

                        # Any other live ERPNext order on the same Hi-Tech SO
                        # (Test-MtSharedHitechOrder). The values go in as JSON
                        # strings, never spliced raw into the filter.
                        $shared = ''
                        if ($hitechSo -ne '') {
                            $sf = '[["' + $script:F_SO + '","=",' + (ConvertTo-Json -InputObject $hitechSo -Compress) + '],["name","!=",' + (ConvertTo-Json -InputObject $name -Compress) + '],["docstatus","<",2]]'
                            $shared = Test-MtSharedHitechOrder -HitechSo $hitechSo -Others @(Get-ErpList -Filters $sf -Fields @('name'))
                        }

                        # Hi-Tech's own order, read this run, against the kilos
                        # recorded here (Resolve-HitechOrderFor, Get-MtHitechCheck).
                        $hitech = ''; $hitechStale = $false
                        if (-not $hitechRead) { throw "Hi-Tech's orders were not read this run, so the kilos cannot be checked against them." }
                        $cands = $null
                        if ($sapOrderByDocNum.ContainsKey($hitechSo)) { $cands = $sapOrderByDocNum[$hitechSo] }
                        $ho = Resolve-HitechOrderFor -Candidates $cands -HitechSo $hitechSo -OrderName $name
                        if ($ho.Problem) { $hitech = $ho.Problem }
                        else {
                            $hc = Get-MtHitechCheck -HitechOrder $ho.Order -ErpItems $items `
                                    -DeliveredKg $dnKgByLine -InvoicedKg $invKgByLine -DeliveryCutoff $cutoff -InvoiceCutoff $invCutoff
                            $hitech = $hc.Message; $hitechStale = [bool]$hc.Stale
                        }

                        $pre  = Get-MtPreSapRefusal -Plan $plan -Items $items -CustomerCode $bpCode `
                                    -HitechStatus (ConvertTo-CleanText (Get-JsonProp $doc $script:F_SO_STAT)) `
                                    -Unit (ConvertTo-CleanText (Get-JsonProp $doc 'custom_company')) `
                                    -Allowlist $mt.ItemAllowlist `
                                    -Approval $approval -Shared $shared -Hitech $hitech -HitechStale $hitechStale
                        $pre  = Get-MtStaleVerdict -PreSap $pre -InPassB ([bool]$passBNames.ContainsKey($name))
                        if ($pre.Action -eq 'skip') { Write-Log INFO ("PASS C {0}: state '{1}' - nothing to do." -f $name, $plan.State); continue }
                        [void]$mtWork.Add(@{ Name = $name; Doc = $doc; Plan = $plan; BpCode = $bpCode; CustomerName = $custName; PreSap = $pre })
                    } catch {
                        # An ERPNext read (or Hi-Tech's orders missing from this
                        # run): transient. Nothing is written on the order; it
                        # stays queued for the next run.
                        Write-Log ERROR ("PASS C {0}: could not be read or checked - left queued for the next run: {1}" -f $name, "$_")
                        $script:Result.failures++
                    }
                }

                if ($mtWork.Count -eq 0) {
                    Write-Log INFO "PASS C: no queued order left to look up - Manna Treads SAP not logged into."
                } else {
                    # ---- 2. one Manna Treads session ----
                    $mtSess = $null
                    try {
                        Assert-MtCompanyDb -CompanyDb $mt.CompanyDb -HitechCompanyDb $companyDb
                        $mtUser = $sapUser; $mtPass = $sapPass
                        if ($mt.Username) { $mtUser = $mt.Username; $mtPass = $mt.Password }
                        # The static Expect100Continue = $false above covers this
                        # host already; this makes sure of it for the ServicePoint
                        # the Hi-Tech session left behind (SAP_ORDER_SYNC.md, and
                        # the empty-body 500 it prevents).
                        try { [System.Net.ServicePointManager]::FindServicePoint([System.Uri]$sapUrl).Expect100Continue = $false } catch { }
                        $mtSess = New-SapWebSession -BaseUrl $sapUrl -Username $mtUser -Password $mtPass `
                            -CompanyDb $mt.CompanyDb -CompanyName 'Manna Treads' -UseSkipCert $useSkip
                        if ($null -ne $sess -and [object]::ReferenceEquals($mtSess, $sess)) {
                            throw "the Manna Treads session is the Hi-Tech one - refusing to create a customer order through it."
                        }

                        foreach ($w in $mtWork) {
                            $name = $w.Name
                            $plan = $w.Plan
                            try {
                                # (a) FIRST: has a previous run already posted it?
                                $q = "NumAtCard eq '$($name -replace "'", "''")'"
                                $rel = "Orders?`$filter=$([uri]::EscapeDataString($q))&`$select=DocEntry,DocNum,Cancelled,DocumentStatus"
                                $hits = @(Invoke-SapGet -BaseUrl $sapUrl -Session $mtSess -RelUrl $rel -PageSize $pageSize -UseSkipCert $useSkip -Label 'Manna Treads Orders by NumAtCard')
                                $decision = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits $hits) -PreSap $w.PreSap

                                if ($decision.Action -eq 'adopt') {
                                    $aNum = "$(Get-JsonProp $decision.Adopt 'DocNum')".Trim()
                                    $aEntry = "$(Get-JsonProp $decision.Adopt 'DocEntry')".Trim()
                                    Write-Log WARN ("PASS C {0}: Manna Treads SAP already has an Order with NumAtCard = '{0}' (DocNum {1}, DocEntry {2}) - ADOPTING it, not creating another." -f $name, $aNum, $aEntry)
                                    if ($DryRun) {
                                        Write-Log INFO ("PASS C {0}: WOULD write {1}={2}, {3}={4}, {5}, clear {6}." -f $name, $script:F_MT_SO, $aNum, $script:F_MT_ENTRY, $aEntry, $script:F_MT_SYNCED, $script:F_MT_ERR)
                                    } else {
                                        try {
                                            Update-ErpSalesOrder -Name $name -Fields @{
                                                $script:F_MT_SO     = $aNum
                                                $script:F_MT_ENTRY  = $aEntry
                                                $script:F_MT_SYNCED = $mtNow
                                                $script:F_MT_ERR    = ''
                                            }
                                        } catch {
                                            Write-Log ERROR ("PASS C {0}: could not record the adopted Manna Treads Order DocNum {1} - it stays queued and the next run adopts it again: {2}" -f $name, $aNum, "$_")
                                            $script:Result.writeErrors++; $script:Result.failures++
                                            continue
                                        }
                                    }
                                    $script:Result.mtAdopted++; $script:Result.changed++
                                    continue
                                }
                                if ($decision.Action -eq 'skip') { continue }
                                if ($decision.Action -eq 'transient') {
                                    # Stale kilos PASS B was due to refresh this run and
                                    # did not (Get-MtStaleVerdict): the run's problem.
                                    if ($DryRun) {
                                        Write-Log INFO ("PASS C {0}: its recorded kilos are not Hi-Tech's yet - PASS B writes them first in a real run (-DryRun wrote nothing), so this is not checked further here: {1}" -f $name, $decision.Message)
                                    } else {
                                        Write-Log ERROR ("PASS C {0}: left queued for the next run - PASS B did not record Hi-Tech's current kilos this run: {1}" -f $name, $decision.Message)
                                        $script:Result.failures++
                                    }
                                    continue
                                }

                                # (b) what ERPNext refused, or two live orders already
                                $why = ''
                                if ($decision.Action -eq 'refuse') { $why = $decision.Message }

                                # (c) the customer and every item must be live - and the
                                #     same product - in Manna Treads SAP
                                if (-not $why) {
                                    $cq = "CardCode eq '$($w.BpCode -replace "'", "''")'"
                                    $crel = "BusinessPartners?`$filter=$([uri]::EscapeDataString($cq))&`$select=CardCode,CardName,CardType,Valid,Frozen,BillToState"
                                    $bpRows = @(Invoke-SapGet -BaseUrl $sapUrl -Session $mtSess -RelUrl $crel -PageSize $pageSize -UseSkipCert $useSkip -Label 'Manna Treads BusinessPartners')
                                    $why = Test-MtCustomer -Rows $bpRows -CardCode $w.BpCode -AllowedStates $mt.AllowedBillToStates -CustomerName "$($w.CustomerName)"
                                }
                                if (-not $why) {
                                    $codes = @($plan.Lines | ForEach-Object { "$($_.Item)" } | Select-Object -Unique)
                                    # ERPNext's own name for each, from the order's lines -
                                    # Test-MtDuplicateLines has already refused an item on two.
                                    $names = @{}
                                    foreach ($it in @(Get-JsonProp $w.Doc 'items')) {
                                        $ic = ConvertTo-CleanText (Get-JsonProp $it 'item_code')
                                        if ($ic -ne '' -and -not $names.ContainsKey($ic)) { $names[$ic] = ConvertTo-CleanText (Get-JsonProp $it 'item_name') }
                                    }
                                    $iq = ($codes | ForEach-Object { "ItemCode eq '$($_ -replace "'", "''")'" }) -join ' or '
                                    $irel = "Items?`$filter=$([uri]::EscapeDataString($iq))&`$select=ItemCode,ItemName,Valid,Frozen,SalesItem"
                                    $itemRows = @(Invoke-SapGet -BaseUrl $sapUrl -Session $mtSess -RelUrl $irel -PageSize $pageSize -UseSkipCert $useSkip -Label 'Manna Treads Items')
                                    $why = Test-MtItems -Codes $codes -Rows $itemRows -Names $names
                                }
                                if ($why) {
                                    $null = Write-MtRefusal -Name $name -Message $why -When $mtNow -IsDryRun ([bool]$DryRun)
                                    continue
                                }

                                # (d) build and create
                                $body = New-MtSalesOrderBody -Plan $plan -CardCode $w.BpCode -OrderName $name `
                                            -HitechSalesOrder (ConvertTo-CleanText (Get-JsonProp $w.Doc $script:F_SO)) `
                                            -DocDate $mtToday -Settings $mt
                                if ($DryRun) {
                                    Write-Log INFO ("PASS C {0}: WOULD POST /Orders to {1} ({2} line(s), billed on what was {3}, {4} incl. GST):`n{5}" -f `
                                        $name, $mt.CompanyDb, $plan.Lines.Count, $plan.Basis, $plan.Total, ($body | ConvertTo-Json -Depth 8))
                                    Write-Log INFO ("PASS C {0}: WOULD then write {1}=<DocNum>, {2}=<DocEntry>, {3}, clear {4}." -f $name, $script:F_MT_SO, $script:F_MT_ENTRY, $script:F_MT_SYNCED, $script:F_MT_ERR)
                                    continue
                                }

                                $post = Invoke-MtSalesOrderPost -BaseUrl $sapUrl -Session $mtSess -Payload $body -UseSkipCert $useSkip
                                if ($null -eq $post.Created) {
                                    $pf = Get-MtPostFailure -Status $post.Status -Body $post.Body
                                    if ($pf.Kind -eq 'refusal') {
                                        $null = Write-MtRefusal -Name $name -Message $pf.Message -When $mtNow -IsDryRun $false
                                    } else {
                                        Write-Log ERROR ("PASS C {0}: the POST failed and was not SAP refusing the order - left queued for the next run (which adopts it by NumAtCard if it was created after all): {1}" -f $name, $post.Text)
                                        $script:Result.failures++
                                    }
                                    continue
                                }
                                $created  = $post.Created
                                $mtNum    = "$(Get-JsonProp $created 'DocNum')".Trim()
                                $mtEntry  = "$(Get-JsonProp $created 'DocEntry')".Trim()
                                Write-Log INFO ("PASS C {0}: Manna Treads Order created - DocNum {1} (DocEntry {2}), {3} line(s), billed on what was {4}, {5} incl. GST." -f `
                                    $name, $mtNum, $mtEntry, $plan.Lines.Count, $plan.Basis, $plan.Total)

                                # write back IMMEDIATELY; the NumAtCard stamp lets the next run adopt it if this fails
                                try {
                                    Update-ErpSalesOrder -Name $name -Fields @{
                                        $script:F_MT_SO     = $mtNum
                                        $script:F_MT_ENTRY  = $mtEntry
                                        $script:F_MT_SYNCED = $mtNow
                                        $script:F_MT_ERR    = ''
                                    }
                                    $script:Result.mtCreated++; $script:Result.changed++
                                } catch {
                                    Write-Log ERROR ("PASS C {0}: Manna Treads Order DocNum {1} WAS CREATED but the ERPNext write-back FAILED: {2}  ==> it stays queued and the next run adopts it via NumAtCard." -f $name, $mtNum, $_)
                                    $script:Result.writeErrors++; $script:Result.failures++
                                }
                            } catch {
                                # A SAP read, or anything else unexpected: transient.
                                # Nothing is written on the order; it stays queued.
                                Write-Log ERROR ("PASS C {0}: FAILED - left queued for the next run: {1}" -f $name, "$_")
                                $script:Result.failures++
                            }
                        }
                    } catch {
                        # Login or the company check: nothing was created, and every
                        # order waiting here is still queued, so the next run
                        # tries again. Their error fields are left empty.
                        Write-Log ERROR ("PASS C: Manna Treads session failed - {0} order(s) left queued for the next run: {1}" -f $mtWork.Count, "$_")
                        $script:Result.failures++
                    } finally {
                        Invoke-SapLogout -BaseUrl $sapUrl -Session $mtSess -UseSkipCert $useSkip
                    }
                }
              } finally {
                Exit-MtPassLock $mtLock
              }
            }
        }

        # ---- summary ----
        $r = $script:Result
        $modeWord = if ($DryRun) { 'DRY-RUN' } else { 'APPLIED' }
        # "mt queued" is what PASS C took this run; "mt refused" were written
        # on their orders and are NOT failures; "mt failed waiting" are orders
        # refused on an earlier run, waiting for the accountant's Try again.
        $summary = ("SUMMARY | {0} | company: {1} | new in scope: {2} | created: {3} | adopted: {4} | create-failed: {5} | rep unmatched: {6} | open polled: {7} | lines invoiced: {8} | orders fully invoiced: {9} | lines written: {10} | corrected: {11} | removed: {12} | invoice lines unresolved: {13} | hitech kg lines: {16} | invoiced but open at Hi-Tech, followed: {21} | mt queued: {17} | mt created: {18} | mt adopted: {19} | mt refused: {20} | mt failed waiting: {22} | write-back errors: {14} | failures: {15}" -f `
            $modeWord, $companyName, $r.inScopeNew, $r.created, $r.adopted, $r.createFailed, $r.repUnmatched, $r.openPolled, $r.linesInvoiced, $r.ordersInvoiced, $r.linesWritten, $r.linesCorrected, $r.linesRemoved, $r.invoiceUnresolved, $r.writeErrors, $r.failures,
            $r.linesKgWritten, $r.mtRequested, $r.mtCreated, $r.mtAdopted, $r.mtRefused, $r.followPolled, $r.mtFailedWaiting)
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
