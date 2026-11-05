<#
.SYNOPSIS
  One-way sync from ONE SAP Business One company (Manna Treads) into ERPNext:
  customer credit limit, total outstanding balance, and an ageing-bucket split
  of the outstanding.

.DESCRIPTION
  Scope: a single SAP company database. Whatever CardCodes come back from that
  database ARE the set of customers we sync - there is no ERPNext-side "Treads"
  filter and this script does not invent one.

  ONE Service Layer login per run does everything (this install has very few
  Service Layer licence seats, so a second login moments later is refused with
  an empty HTTP 500 - see README). In that one session the script reads:
    - BusinessPartners : CardCode, CardName, CreditLimit, CurrentAccountBalance
    - Invoices    (DocumentStatus eq 'bost_Open') : per-doc open amount + date
    - CreditNotes (DocumentStatus eq 'bost_Open') : per-doc open amount + date
  then logs out (in a finally, always).

  Fields written to ERPNext Customer, matched on custom_bp_code ONLY (never by
  name), and only when the value actually changed:
    custom_credit_limit          <- SAP CreditLimit            (see rules below)
    custom_outstanding_balance   <- SAP CurrentAccountBalance   (or bucket sum)
    custom_outstanding_0_30      \
    custom_outstanding_30_60      >  open AR (invoices - credit notes), aged by
    custom_outstanding_60_90     /   posting date (config: ageing_basis)
    custom_outstanding_90_plus   /
    custom_sap_last_synced       <- run timestamp, only when something changed

  Payment terms (added 11 Oct 2026; written only once the three fields exist
  on the ERPNext Customer - until then the run logs a WARN and skips them):
    custom_payment_terms         <- the SAP term's name (BP PayTermsGrpCode)
    custom_overdue_past_terms    <- open amount on INVOICES whose SAP due date
                                    (set from the payment terms) has passed,
                                    capped at CurrentAccountBalance so payments
                                    on account count; 0 when the customer has no
                                    term set (SAP '- Cash Basic -', code -1)
    custom_overdue_days          <- days the oldest of those invoices is past due
  Both apps escalate an order to the GM when custom_overdue_past_terms > 1
  (shared/fixtures/credit.json, past_terms). This script is the ONE place that
  decides what "overdue past terms" means.

  Credit-limit rules (unchanged):
    - A SAP CreditLimit of 0 is the Business One default meaning "no figure",
      not "a deliberate 0" - it is SKIPPED so a hand-typed limit is never wiped.
    - write_mode "fill_blanks" only sets a limit that is currently empty in ERPNext.
    - A code not in the SAP book is LEFT COMPLETELY ALONE (no write, no 0, no
      stamp) for every field. "Not in the SAP book" means "no information".

  Outstanding rules:
    - Outstanding is always SAP-authoritative for a MATCHED customer, so a
      customer with no open documents is written down to 0 (stale figures are
      cleared). A 0 here is real, unlike a 0 credit limit.
    - If the open-document read fails, the run still syncs the total balance from
      CurrentAccountBalance but leaves the four bucket fields untouched (it will
      not zero them from a failed read).

  Never touched: ERPNext's standard `credit_limits` child table (writing it would
  switch on ERPNext's own order-blocking credit control).

.PARAMETER ConfigPath
  Path to the JSON config file. Required. Credentials never live in this script.

.PARAMETER DryRun
  Read everything, write nothing, print the full summary. RUN THIS FIRST.

.PARAMETER Limit
  Apply at most N customer writes this run (ordered by bp_code, so stable).
  0 = no cap. For a careful first look at a few real writes.

.PARAMETER ResultJsonPath
  If given, a small JSON summary of the run is written here (whether it
  succeeded or threw). The SAP-sync poller reads this to report status back to
  ERPNext. Contains: exitCode, dryRun, company, sapRows, matched, limitChanges,
  balanceChanges, bucketsWritten, customersChanged, failures, summary,
  startedAt, finishedAt, elapsedSec, error.

.EXAMPLE
  .\Sync-SapCreditLimits.ps1 -ConfigPath .\config.json -DryRun

.EXAMPLE
  .\Sync-SapCreditLimits.ps1 -ConfigPath .\config.json -Limit 5
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
$script:Result           = [ordered]@{
    exitCode         = 1
    dryRun           = [bool]$DryRun
    company          = $null
    sapRows          = 0
    matched          = 0
    limitChanges     = 0
    balanceChanges   = 0
    bucketsWritten   = $false
    customersChanged = 0
    failures         = 0
    summary          = $null
    error            = $null
    startedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    finishedAt       = $null
    elapsedSec       = 0
}

# ERPNext custom fieldnames (single source of truth).
$script:F_LIMIT   = 'custom_credit_limit'
$script:F_BAL     = 'custom_outstanding_balance'
$script:F_B1      = 'custom_outstanding_0_30'
$script:F_B2      = 'custom_outstanding_30_60'
$script:F_B3      = 'custom_outstanding_60_90'
$script:F_B4      = 'custom_outstanding_90_plus'
$script:F_STAMP   = 'custom_sap_last_synced'
$script:F_TERMS   = 'custom_payment_terms'       # 11 Oct 2026
$script:F_OVERDUE = 'custom_overdue_past_terms'  # 11 Oct 2026
$script:F_ODAYS   = 'custom_overdue_days'        # 11 Oct 2026
$script:NO_TERMS_CODE = -1                       # SAP '- Cash Basic -' = no term set
$script:TermsFieldsReady = $false                # set at run start: do the three fields exist?
$script:MONEY_EPS = 0.005   # treat differences below this as "equal"

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
    # Safe property read for ConvertFrom-Json objects, including names with dots
    # or '@' (e.g. 'odata.nextLink', '@odata.nextLink').
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
    if ([double]::TryParse($s, [ref] $d)) { return $d }
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
    # No silent fallback. A mistyped key that quietly became a default is exactly
    # how the wrong site / wrong company database gets written to.
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

function Get-OptionalBool {
    param($Object, [string] $Name, [bool] $Default)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p) { return $Default }
    return [bool] $p.Value
}

function Get-OptionalEnum {
    param($Object, [string] $Name, [string[]] $Allowed, [string] $Default)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or -not "$($p.Value)".Trim()) { return $Default }
    $v = "$($p.Value)".Trim().ToLower()
    if ($Allowed -notcontains $v) {
        throw ("config: '{0}' must be one of: {1} (got '{2}')." -f $Name, ($Allowed -join ', '), $v)
    }
    return $v
}

function Write-UnknownKeyWarnings {
    # We do not silently accept keys we do not read.
    param($Object, [string[]] $Known, [string] $PathLabel)
    if ($null -eq $Object) { return }
    foreach ($prop in $Object.PSObject.Properties) {
        if ($Known -notcontains $prop.Name) {
            Write-Log WARN ("config: '{0}.{1}' is not read by this script - safe to delete, but check it is not a typo of a real key." -f $PathLabel, $prop.Name)
        }
    }
}

function Format-HttpError {
    # Both systems put the real reason in the RESPONSE BODY, not the status line.
    # SAP B1:  { "error": { "code": n, "message": { "value": "..." } } }
    # Frappe:  { "exception": "...", "message": "..." }
    param($ErrorRecord, [string] $Context)

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
            if (-not $detail) { $fm = Get-JsonProp $j 'message';   if ($fm) { $detail = "$fm" } }
        } catch {
            $detail = "$body"
        }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) + ' ...' }
    return ('{0}: {1}' -f $Context, $detail)
}

# --------------------------------------------------------------------------------
# ERPNext
# --------------------------------------------------------------------------------

function Invoke-ErpApi {
    param(
        [string] $Method,
        [string] $Path,      # e.g. /api/resource/Customer/NAME
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
        $splat.Body        = ($Body | ConvertTo-Json -Depth 5 -Compress)
        $splat.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @splat
    } catch {
        throw (Format-HttpError $_ "ERPNext $Method $Path")
    }
}

function Test-ErpTermsFields {
    # Do the three payment-terms fields exist on ERPNext Customer yet? Asked by
    # reading one customer with them: Frappe refuses a field list naming a
    # column it does not have. Any refusal means "not yet" - the run then
    # carries on exactly as it did before 11 Oct 2026.
    $fields = '["name","' + $script:F_TERMS + '","' + $script:F_OVERDUE + '","' + $script:F_ODAYS + '"]'
    $query  = 'fields=' + [uri]::EscapeDataString($fields) + '&limit_page_length=1'
    try {
        $null = Invoke-ErpApi -Method 'GET' -Path '/api/resource/Customer' -Query $query
        return $true
    } catch {
        return $false
    }
}

function Get-ErpCodedCustomers {
    # ONE request for every coded customer, then an in-memory index.
    # limit_page_length=0 disables Frappe paging.
    $fieldList = @('name', 'custom_bp_code',
        $script:F_LIMIT, $script:F_BAL,
        $script:F_B1, $script:F_B2, $script:F_B3, $script:F_B4)
    if ($script:TermsFieldsReady) { $fieldList += @($script:F_TERMS, $script:F_OVERDUE, $script:F_ODAYS) }
    $fields  = '[' + (($fieldList | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
    $filters = '[["custom_bp_code","is","set"]]'
    $query   = 'fields='  + [uri]::EscapeDataString($fields) +
               '&filters=' + [uri]::EscapeDataString($filters) +
               '&limit_page_length=0'

    $resp = Invoke-ErpApi -Method 'GET' -Path '/api/resource/Customer' -Query $query
    $data = Get-JsonProp $resp 'data'
    if ($null -eq $data) { throw "ERPNext returned no 'data' array when listing coded customers." }

    $index = @{}   # bp_code -> record   (hashtable keys are case-insensitive)
    $dupes = New-Object System.Collections.Generic.List[string]
    foreach ($row in $data) {
        $code = "$(Get-JsonProp $row 'custom_bp_code')".Trim()
        if ($code -eq '') { continue }
        if ($index.ContainsKey($code)) { $dupes.Add($code); continue }
        $index[$code] = [pscustomobject]@{
            Name       = "$(Get-JsonProp $row 'name')"
            BpCode     = $code
            Matched    = $false
            CurLimit   = [double](ConvertTo-Number (Get-JsonProp $row $script:F_LIMIT))
            CurBalance = [double](ConvertTo-Number (Get-JsonProp $row $script:F_BAL))
            CurB1      = [double](ConvertTo-Number (Get-JsonProp $row $script:F_B1))
            CurB2      = [double](ConvertTo-Number (Get-JsonProp $row $script:F_B2))
            CurB3      = [double](ConvertTo-Number (Get-JsonProp $row $script:F_B3))
            CurB4      = [double](ConvertTo-Number (Get-JsonProp $row $script:F_B4))
            CurTerms   = "$(Get-JsonProp $row $script:F_TERMS)".Trim()
            CurOverdue = [double](ConvertTo-Number (Get-JsonProp $row $script:F_OVERDUE))
            CurODays   = [int](ConvertTo-Number (Get-JsonProp $row $script:F_ODAYS))
        }
    }
    if ($dupes.Count -gt 0) {
        # If codes stop being unique we must NOT pick one row arbitrarily and write to it.
        throw ("ERPNext has duplicate custom_bp_code value(s): {0}. Resolve before syncing." -f (($dupes | Select-Object -Unique) -join ', '))
    }
    return $index
}

# --------------------------------------------------------------------------------
# SAP Business One Service Layer
# --------------------------------------------------------------------------------

function Enable-SapCertBypass {
    # Host-scoped certificate bypass for Windows PowerShell 5.1, as a COMPILED
    # delegate - not a PowerShell scriptblock. Assigning a scriptblock to
    # ServerCertificateValidationCallback breaks TLS for *other* hosts on 5.1
    # ("The underlying connection was closed: an unexpected error occurred on a
    # send"), which would also take out the ERPNext HTTPS calls. This delegate
    # accepts a bad cert ONLY for the SAP host; ERPNext keeps real validation.
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
    # Log in to the Service Layer and hand back a WebRequestSession whose cookie
    # jar carries B1SESSION (+ B1SESSION2) and ROUTEID (load-balancer stickiness).
    #
    # We rely on the cookie CONTAINER (-SessionVariable / -WebSession), NOT a
    # hand-built "Cookie:" header. Windows PowerShell 5.1's Invoke-RestMethod
    # silently discards a Cookie header supplied through -Headers when there is
    # no -WebSession, so every follow-up call then reaches the SL with no session
    # at all - the load balancer access log shows it as  sid=- n=-  and the SL
    # answers 301 "Invalid session" / 401, and the later Logout misses too so the
    # session leaks (a pile of leaked sessions is what finally makes /Login
    # return an empty-body HTTP 500).
    #
    # If the jar really does come back without B1SESSION (the old "IP host loses
    # the cookie" worry) we repopulate it with CookieContainer.SetCookies, then
    # fall back to the body's SessionId. A plain curl cookie jar round-trips
    # these same cookies to the same bare-IP host fine, so the container is
    # enough in practice.
    param(
        [string] $BaseUrl,
        [string] $Username,
        [string] $Password,
        [string] $CompanyDb,
        [string] $CompanyName,
        [bool]   $UseSkipCert
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

    # The Service Layer intermittently answers /Login with an empty-body HTTP 500
    # or 503 - a node warming up after a restart, a transient licence-server
    # hiccup, or a rejected request while the (small) SL licence pool is briefly
    # full. These clear on their own, so retry a few times, backing off. A
    # 400/401 (bad credentials / company) is final and is not retried.
    $resp = $null
    $maxTries = 4
    for ($try = 1; $try -le $maxTries; $try++) {
        try {
            $resp = Invoke-WebRequest @loginSplat
            break
        } catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            }
            $retryable = ($code -eq 500 -or $code -eq 502 -or $code -eq 503 -or $code -eq 504 -or $null -eq $code)
            if (-not $retryable -or $try -eq $maxTries) {
                throw (Format-HttpError $_ "SAP Login [$CompanyName / $CompanyDb] (attempt $try/$maxTries)")
            }
            $wait = 5 * $try
            $codeText = if ($null -eq $code) { 'no response' } else { "$code" }
            Write-Log WARN ("SAP [{0}] login attempt {1}/{2} failed (HTTP {3}); retrying in {4}s" -f $CompanyName, $try, $maxTries, $codeText, $wait)
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
            try {
                $sess.Cookies.Add((New-Object System.Net.Cookie('B1SESSION', "$sid", '/', $u.Host)))
                $names = Get-JarNames $sess
            } catch { }
        }
    }
    if ($names -notcontains 'B1SESSION') {
        throw "SAP Login [$CompanyName / $CompanyDb]: authenticated but could not obtain a B1SESSION cookie or SessionId."
    }
    Write-Log INFO ("SAP [{0}] login OK (session cookies: {1})" -f $CompanyName, ($names -join ','))
    return $sess
}

function Get-SapPagedValue {
    # GET an OData collection through the given WebSession, following
    # odata.nextLink to the end. Returns a List of the raw 'value' rows.
    param(
        [string] $BaseUrl,
        $Session,
        [string] $StartUrl,
        [int]    $PageSize,
        [bool]   $UseSkipCert,
        [string] $Label
    )
    $rows  = New-Object System.Collections.Generic.List[object]
    $pages = 0
    $next  = $StartUrl
    while ($next) {
        $pages++
        $getSplat = @{
            Method      = 'Get'; Uri = $next
            Headers     = @{ Prefer = "odata.maxpagesize=$PageSize" }
            WebSession  = $Session
            ErrorAction = 'Stop'; TimeoutSec = 180
        }
        if ($UseSkipCert) { $getSplat.SkipCertificateCheck = $true }
        try {
            $resp = Invoke-RestMethod @getSplat
        } catch {
            throw (Format-HttpError $_ "SAP read $Label page $pages")
        }

        $value = Get-JsonProp $resp 'value'
        if ($value) { foreach ($row in $value) { $rows.Add($row) } }

        $link = Get-JsonProp $resp 'odata.nextLink'
        if (-not $link) { $link = Get-JsonProp $resp '@odata.nextLink' }
        if ($link) {
            $link = "$link"
            if ($link -match '^https?://') {
                $next = $link
            } elseif ($link.StartsWith('/')) {
                $uu = [System.Uri] $BaseUrl
                $next = ('{0}://{1}{2}' -f $uu.Scheme, $uu.Authority, $link)
            } else {
                $next = "$BaseUrl/" + $link
            }
        } else {
            $next = $null
        }
    }
    Write-Log INFO ("SAP read {0}: {1} row(s) over {2} page(s)" -f $Label, $rows.Count, $pages)
    return $rows
}

function Get-AgeBucketKey {
    # 0-30 -> B1 ; 31-60 -> B2 ; 61-90 -> B3 ; 90+ -> B4. Future-dated / not yet
    # due (negative age) falls in the first bucket.
    param([int] $AgeDays)
    if ($AgeDays -le 30) { return 'B1' }
    if ($AgeDays -le 60) { return 'B2' }
    if ($AgeDays -le 90) { return 'B3' }
    return 'B4'
}

function Get-SapCustomerData {
    # ONE Service Layer session: customers + open AR documents. Returns:
    #   @{ ByCode = @{ code -> record }; ArAvailable = [bool] }
    # record: CardCode, CardName, CreditLimit, AccountBalance,
    #         B1..B4 (bucket amounts), BucketSum, HasArDocs
    param(
        [string] $BaseUrl,
        [string] $Username,
        [string] $Password,
        [string] $CompanyDb,
        [string] $CompanyName,
        [int]    $PageSize,
        [string] $AgeingBasis,   # 'posting_date' | 'due_date'
        [bool]   $SyncOutstanding
    )

    $useSkip     = ($script:SapSkipCert -and $PSVersionTable.PSVersion.Major -ge 6)
    $sess        = $null
    $bpRows      = $null
    $arAvailable = $false
    $ar          = @{}   # code -> @{ B1;B2;B3;B4; n }
    $pastDue     = @{}   # code -> @{ Amt; Late }  open invoices past their SAP due date (11 Oct 2026)
    $termNames   = @{}   # PayTermsGrpCode -> PaymentTermsGroupName
    $basisField  = if ($AgeingBasis -eq 'due_date') { 'DocDueDate' } else { 'DocDate' }
    $today       = (Get-Date).Date

    try {
        $sess = New-SapWebSession -BaseUrl $BaseUrl -Username $Username -Password $Password `
            -CompanyDb $CompanyDb -CompanyName $CompanyName -UseSkipCert $useSkip

        # ---- customers ----
        $bpSel = [uri]::EscapeDataString('CardCode,CardName,CreditLimit,CurrentAccountBalance,PayTermsGrpCode')
        $bpFlt = [uri]::EscapeDataString("CardType eq 'cCustomer'")
        $bpRows = Get-SapPagedValue -BaseUrl $BaseUrl -Session $sess -PageSize $PageSize -UseSkipCert $useSkip `
            -Label "BusinessPartners [$CompanyName]" `
            -StartUrl "$BaseUrl/BusinessPartners?`$select=$bpSel&`$filter=$bpFlt"

        # ---- payment-term names (11 Oct 2026). A failure costs only the names. ----
        try {
            $ptSel  = [uri]::EscapeDataString('GroupNumber,PaymentTermsGroupName')
            $ptRows = Get-SapPagedValue -BaseUrl $BaseUrl -Session $sess -PageSize $PageSize -UseSkipCert $useSkip `
                -Label "PaymentTermsTypes [$CompanyName]" `
                -StartUrl "$BaseUrl/PaymentTermsTypes?`$select=$ptSel"
            foreach ($t in $ptRows) { $termNames["$(Get-JsonProp $t 'GroupNumber')".Trim()] = "$(Get-JsonProp $t 'PaymentTermsGroupName')".Trim() }
        } catch {
            Write-Log WARN ("SAP payment-term names could not be read - the terms field will be left as it is. Reason: {0}" -f $_.Exception.Message)
        }

        # ---- open AR documents (only if we are going to write buckets) ----
        if ($SyncOutstanding) {
            try {
                $docSel = [uri]::EscapeDataString('CardCode,DocDate,DocDueDate,DocTotal,PaidToDate')
                $openF  = [uri]::EscapeDataString("DocumentStatus eq 'bost_Open'")

                $addDoc = {
                    param($d, [int] $sign)
                    $code = "$(Get-JsonProp $d 'CardCode')".Trim()
                    if ($code -eq '') { return }
                    $open = [double](ConvertTo-Number (Get-JsonProp $d 'DocTotal')) -
                            [double](ConvertTo-Number (Get-JsonProp $d 'PaidToDate'))
                    if ([math]::Abs($open) -lt $script:MONEY_EPS) { return }
                    $basis = Get-JsonProp $d $basisField
                    if (-not $basis) { $basis = Get-JsonProp $d 'DocDate' }
                    $age = 0
                    try { $age = [int][math]::Floor(($today - ([datetime]$basis).Date).TotalDays) } catch { $age = 0 }
                    if (-not $ar.ContainsKey($code)) { $ar[$code] = @{ B1 = 0.0; B2 = 0.0; B3 = 0.0; B4 = 0.0; n = 0 } }
                    $k = Get-AgeBucketKey $age
                    $ar[$code][$k] += ($sign * $open)
                    $ar[$code].n++

                    # Overdue past the payment terms (11 Oct 2026): an INVOICE still
                    # open after its SAP due date, which SAP set from the terms.
                    if ($sign -gt 0 -and $open -gt $script:MONEY_EPS) {
                        $dueRaw = Get-JsonProp $d 'DocDueDate'
                        if ($dueRaw) {
                            try {
                                $dueDay = ([datetime]$dueRaw).Date
                                if ($dueDay -lt $today) {
                                    $lateDays = [int][math]::Floor(($today - $dueDay).TotalDays)
                                    if (-not $pastDue.ContainsKey($code)) { $pastDue[$code] = @{ Amt = 0.0; Late = 0 } }
                                    $pastDue[$code].Amt += $open
                                    if ($lateDays -gt $pastDue[$code].Late) { $pastDue[$code].Late = $lateDays }
                                }
                            } catch { }
                        }
                    }
                }

                $invRows = Get-SapPagedValue -BaseUrl $BaseUrl -Session $sess -PageSize $PageSize -UseSkipCert $useSkip `
                    -Label "open Invoices [$CompanyName]" `
                    -StartUrl "$BaseUrl/Invoices?`$select=$docSel&`$filter=$openF"
                foreach ($d in $invRows) { & $addDoc $d 1 }

                $cnRows = Get-SapPagedValue -BaseUrl $BaseUrl -Session $sess -PageSize $PageSize -UseSkipCert $useSkip `
                    -Label "open CreditNotes [$CompanyName]" `
                    -StartUrl "$BaseUrl/CreditNotes?`$select=$docSel&`$filter=$openF"
                foreach ($d in $cnRows) { & $addDoc $d -1 }

                $arAvailable = $true
            } catch {
                Write-Log WARN ("SAP open-document read failed - bucket fields will NOT be written this run (total balance still syncs from CurrentAccountBalance). Reason: {0}" -f $_.Exception.Message)
                $arAvailable = $false
            }
        }
    }
    finally {
        # ALWAYS log out - this install has very few SL licence seats and a leaked
        # session keeps a seat until it times out.
        if ($sess) {
            try {
                $outSplat = @{ Method = 'Post'; Uri = "$BaseUrl/Logout"; WebSession = $sess; ErrorAction = 'Stop'; TimeoutSec = 60 }
                if ($useSkip) { $outSplat.SkipCertificateCheck = $true }
                $null = Invoke-RestMethod @outSplat
                Write-Log INFO "SAP [$CompanyName] logout OK"
            } catch {
                Write-Log WARN ("SAP [{0}] logout failed: {1}" -f $CompanyName, $_.Exception.Message)
            }
        }
    }

    # ---- assemble per-code records ----
    $byCode = @{}
    foreach ($bp in $bpRows) {
        $code = "$(Get-JsonProp $bp 'CardCode')".Trim()
        if ($code -eq '') { continue }
        if ($byCode.ContainsKey($code)) {
            Write-Log WARN ("SAP returned CardCode {0} more than once - keeping the first." -f $code)
            continue
        }
        $b1 = 0.0; $b2 = 0.0; $b3 = 0.0; $b4 = 0.0; $hasDocs = $false
        if ($arAvailable -and $ar.ContainsKey($code)) {
            $b1 = [math]::Round($ar[$code].B1, 2)
            $b2 = [math]::Round($ar[$code].B2, 2)
            $b3 = [math]::Round($ar[$code].B3, 2)
            $b4 = [math]::Round($ar[$code].B4, 2)
            $hasDocs = ($ar[$code].n -gt 0)
        }
        $acctBal = [double](ConvertTo-Number (Get-JsonProp $bp 'CurrentAccountBalance'))

        # Payment terms (11 Oct 2026). No term set (SAP code -1, '- Cash Basic -')
        # means nothing can be "past the terms", so its figure is 0. The amount
        # is capped at the account balance: a payment on account that SAP has
        # not reconciled against the invoices still counts as paid.
        $payRaw   = Get-JsonProp $bp 'PayTermsGrpCode'
        $payCode  = if ($null -eq $payRaw -or "$payRaw".Trim() -eq '') { $script:NO_TERMS_CODE } else { [int](ConvertTo-Number $payRaw) }
        $termsSet = ($payCode -ne $script:NO_TERMS_CODE)
        $termName = if ($termNames.ContainsKey("$payCode")) { $termNames["$payCode"] } else { '' }
        $odAmt = $null; $odDays = $null           # $null = unknown this run: leave the fields alone
        if ($arAvailable) {
            $odAmt = 0.0; $odDays = 0
            if ($termsSet -and $pastDue.ContainsKey($code)) {
                $odAmt = [math]::Round([math]::Max(0.0, [math]::Min([double]$pastDue[$code].Amt, $acctBal)), 2)
                if ($odAmt -gt 0) { $odDays = [int]$pastDue[$code].Late }
            }
        }

        $byCode[$code] = [pscustomobject]@{
            CardCode       = $code
            CardName       = "$(Get-JsonProp $bp 'CardName')"
            CreditLimit    = [double](ConvertTo-Number (Get-JsonProp $bp 'CreditLimit'))
            AccountBalance = $acctBal
            B1             = $b1
            B2             = $b2
            B3             = $b3
            B4             = $b4
            BucketSum      = [math]::Round($b1 + $b2 + $b3 + $b4, 2)
            HasArDocs      = $hasDocs
            PaymentTerms   = $termName
            OverduePastTerms = $odAmt
            OverdueDays    = $odDays
        }
    }
    return @{ ByCode = $byCode; ArAvailable = $arAvailable }
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
    $script:ErpBaseUrl = Get-RequiredString $erp 'site'       'erpnext'
    $erpKey            = Get-RequiredString $erp 'api_key'    'erpnext'
    $erpSecret         = Get-RequiredString $erp 'api_secret' 'erpnext'
    $script:ErpAuthHeader = "token ${erpKey}:${erpSecret}"
    Write-UnknownKeyWarnings $erp @('site', 'api_key', 'api_secret') 'erpnext'

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

    $pageSize = 200
    $pp = $sap.PSObject.Properties['page_size']
    if ($pp -and $pp.Value) { $pageSize = [int]$pp.Value }

    $companies = @(Get-JsonProp $sap 'companies')
    if ($companies.Count -ne 1) {
        throw ("config: sap.companies must contain exactly ONE entry (this build syncs a single company). Found {0}." -f $companies.Count)
    }
    $company     = $companies[0]
    $companyName = Get-RequiredString $company 'name'       'sap.companies[0]'
    $companyDb   = Get-RequiredString $company 'company_db' 'sap.companies[0]'
    Write-UnknownKeyWarnings $company @('name', 'company_db') 'sap.companies[0]'
    Write-UnknownKeyWarnings $sap @('url', 'username', 'password', 'verify_ssl', 'page_size', 'companies') 'sap'

    # ---- Sync policy ----
    $writeMode = (Get-RequiredString $config 'write_mode' '(root)').ToLower()
    if ($writeMode -ne 'overwrite' -and $writeMode -ne 'fill_blanks') {
        throw "config: 'write_mode' must be 'overwrite' or 'fill_blanks' (got '$writeMode')."
    }
    $syncLimit       = Get-OptionalBool $config 'sync_credit_limit' $true
    $syncOutstanding = Get-OptionalBool $config 'sync_outstanding'  $true
    $ageingBasis     = Get-OptionalEnum $config 'ageing_basis'      @('posting_date', 'due_date')       'posting_date'
    $outstandingTot  = Get-OptionalEnum $config 'outstanding_total' @('account_balance', 'bucket_sum')  'account_balance'
    if (-not $syncLimit -and -not $syncOutstanding) {
        throw "config: both 'sync_credit_limit' and 'sync_outstanding' are false - nothing to do."
    }

    $skipCodes = @()
    $scp = $config.PSObject.Properties['skip_codes']
    if ($scp -and $scp.Value) {
        $skipCodes = @($scp.Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
    }

    # ---- Logging ----
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
    $retentionDays = 30
    $lk = $config.PSObject.Properties['log_keep_days']
    if ($lk -and $lk.Value) { $retentionDays = [int]$lk.Value }
    $script:LogFile = Join-Path $logDir ('sap-credit-sync-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

    Write-UnknownKeyWarnings $config @('erpnext', 'sap', 'write_mode',
        'sync_credit_limit', 'sync_outstanding', 'ageing_basis', 'outstanding_total',
        'skip_codes', 'log_dir', 'log_keep_days') '(root)'

    Write-Log INFO ("==== run start ==== company='{0}' db='{1}' DryRun={2} Limit={3} writeMode={4} syncLimit={5} syncOutstanding={6} ageing={7} total={8} PS={9}" -f `
        $companyName, $companyDb, [bool]$DryRun, $Limit, $writeMode, $syncLimit, $syncOutstanding, $ageingBasis, $outstandingTot, $PSVersionTable.PSVersion)

    try {
        Get-ChildItem -LiteralPath $logDir -Filter 'sap-credit-sync-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-Log WARN "log prune failed: $($_.Exception.Message)" }

    # ---- TLS / certificate handling ----
    $script:PrevCertCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.SecurityProtocolType]::Tls12 -bor
            [System.Net.SecurityProtocolType]::Tls11 -bor
            [System.Net.SecurityProtocolType]::Tls
    }
    if ($script:SapSkipCert) {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Enable-SapCertBypass -SapHost ([System.Uri]$sapUrl).Host
            Write-Log WARN ("TLS cert validation bypassed for SAP host '{0}' only (verify_ssl=false)." -f ([System.Uri]$sapUrl).Host)
        } else {
            Write-Log WARN "TLS cert validation bypassed for SAP calls via -SkipCertificateCheck (verify_ssl=false, PowerShell 7 path)."
        }
    }

    try {
        # ---- 1. ERPNext bulk read ----
        # Payment terms (11 Oct 2026) are written only once their three fields
        # exist on Customer; before that the run is exactly what it always was.
        $script:TermsFieldsReady = Test-ErpTermsFields
        if ($script:TermsFieldsReady) {
            Write-Log INFO ("payment-terms fields found on Customer ({0}, {1}, {2}) - they will be synced." -f $script:F_TERMS, $script:F_OVERDUE, $script:F_ODAYS)
        } else {
            Write-Log WARN ("payment-terms fields are not on ERPNext Customer yet ({0}, {1}, {2}) - skipped this run." -f $script:F_TERMS, $script:F_OVERDUE, $script:F_ODAYS)
        }
        Write-Log INFO "Loading ERPNext customers that carry a custom_bp_code ..."
        $erpIndex = Get-ErpCodedCustomers
        Write-Log INFO ("ERPNext: {0} coded customer(s) indexed." -f $erpIndex.Count)

        # ---- 2. SAP read (one session: customers + open AR) ----
        # If this throws we go straight to the fatal handler: non-zero exit and
        # NOTHING written, because the write phase is below this point.
        $sapData     = Get-SapCustomerData -BaseUrl $sapUrl -Username $sapUser -Password $sapPass `
            -CompanyDb $companyDb -CompanyName $companyName -PageSize $pageSize `
            -AgeingBasis $ageingBasis -SyncOutstanding $syncOutstanding
        $sapByCode   = $sapData.ByCode
        $arAvailable = $sapData.ArAvailable
        $writeBuckets = ($syncOutstanding -and $arAvailable)
        Write-Log INFO ("SAP [{0}]: {1} distinct customer CardCode(s). Bucket fields this run: {2}" -f `
            $companyName, $sapByCode.Count, ($(if ($writeBuckets) { 'YES' } elseif ($syncOutstanding) { 'NO (open-doc read failed)' } else { 'NO (sync_outstanding=false)' })))

        # ---- 3. Match on custom_bp_code ONLY, build per-customer change set ----
        $plannedWrites    = New-Object System.Collections.Generic.List[object]
        $sapCodesNoErp    = New-Object System.Collections.Generic.List[string]
        $nonStandardCodes = New-Object System.Collections.Generic.List[string]
        $skippedByConfig  = New-Object System.Collections.Generic.List[string]
        $sapNoFigure      = New-Object System.Collections.Generic.List[string]
        $limitChangeCount = 0
        $balChangeCount   = 0
        $termsChangeCount = 0
        $overdueNow       = 0     # matched customers overdue past their terms this run

        foreach ($code in ($sapByCode.Keys | Sort-Object)) {
            if ($skipCodes -contains $code) { $skippedByConfig.Add($code); continue }
            if ($code -notmatch '^C-\d+$') { $nonStandardCodes.Add($code) }   # e.g. a stray 'S-####' or a code with a space

            if (-not $erpIndex.ContainsKey($code)) { $sapCodesNoErp.Add($code); continue }

            $erpCust = $erpIndex[$code]
            $erpCust.Matched = $true
            $sapCust = $sapByCode[$code]

            $fields   = @{}
            $limitFrom = $null; $limitTo = $null
            $balFrom   = $null; $balTo   = $null
            $bucketsChanged = $false

            # -- credit limit --
            if ($syncLimit) {
                $desired = [double]$sapCust.CreditLimit
                $current = [double]$erpCust.CurLimit
                if ($desired -le 0) {
                    $sapNoFigure.Add($code)                       # 0 = "no figure" - never wipe a hand-typed limit
                } elseif ($writeMode -eq 'fill_blanks' -and $current -ne 0) {
                    # leave it - fill_blanks only sets an empty limit
                } elseif ([math]::Abs($desired - $current) -ge $script:MONEY_EPS) {
                    $fields[$script:F_LIMIT] = $desired
                    $limitFrom = $current; $limitTo = $desired
                    $limitChangeCount++
                }
            }

            # -- outstanding balance + buckets --
            if ($syncOutstanding) {
                $desiredBal = if ($outstandingTot -eq 'bucket_sum' -and $writeBuckets) { [double]$sapCust.BucketSum } else { [double]$sapCust.AccountBalance }
                $desiredBal = [math]::Round($desiredBal, 2)
                if ([math]::Abs($desiredBal - [double]$erpCust.CurBalance) -ge $script:MONEY_EPS) {
                    $fields[$script:F_BAL] = $desiredBal
                    $balFrom = [double]$erpCust.CurBalance; $balTo = $desiredBal
                    $balChangeCount++
                }
                if ($writeBuckets) {
                    if ([math]::Abs([double]$sapCust.B1 - [double]$erpCust.CurB1) -ge $script:MONEY_EPS) { $fields[$script:F_B1] = [double]$sapCust.B1; $bucketsChanged = $true }
                    if ([math]::Abs([double]$sapCust.B2 - [double]$erpCust.CurB2) -ge $script:MONEY_EPS) { $fields[$script:F_B2] = [double]$sapCust.B2; $bucketsChanged = $true }
                    if ([math]::Abs([double]$sapCust.B3 - [double]$erpCust.CurB3) -ge $script:MONEY_EPS) { $fields[$script:F_B3] = [double]$sapCust.B3; $bucketsChanged = $true }
                    if ([math]::Abs([double]$sapCust.B4 - [double]$erpCust.CurB4) -ge $script:MONEY_EPS) { $fields[$script:F_B4] = [double]$sapCust.B4; $bucketsChanged = $true }
                }
            }

            # -- payment terms + overdue past them (11 Oct 2026) --
            $termsFrom = $null; $termsTo = $null
            if ($null -ne $sapCust.OverduePastTerms -and [double]$sapCust.OverduePastTerms -gt 1) { $overdueNow++ }
            if ($script:TermsFieldsReady) {
                # The name is only written when SAP gave one; a failed name read
                # never blanks a stored term.
                if ($sapCust.PaymentTerms -ne '' -and $sapCust.PaymentTerms -ne $erpCust.CurTerms) {
                    $fields[$script:F_TERMS] = $sapCust.PaymentTerms
                }
                # $null = the open-document read failed: leave the figures alone.
                if ($null -ne $sapCust.OverduePastTerms) {
                    $odChanged = $false
                    if ([math]::Abs([double]$sapCust.OverduePastTerms - [double]$erpCust.CurOverdue) -ge $script:MONEY_EPS) {
                        $fields[$script:F_OVERDUE] = [double]$sapCust.OverduePastTerms; $odChanged = $true
                    }
                    if ([int]$sapCust.OverdueDays -ne [int]$erpCust.CurODays) {
                        $fields[$script:F_ODAYS] = [int]$sapCust.OverdueDays; $odChanged = $true
                    }
                    if ($odChanged) { $termsFrom = [double]$erpCust.CurOverdue; $termsTo = [double]$sapCust.OverduePastTerms; $termsChangeCount++ }
                }
            }

            if ($fields.Count -eq 0) { continue }

            $plannedWrites.Add([pscustomobject]@{
                Code           = $code
                Name           = $erpCust.Name
                Fields         = $fields
                LimitFrom      = $limitFrom
                LimitTo        = $limitTo
                BalFrom        = $balFrom
                BalTo          = $balTo
                BucketsChanged = $bucketsChanged
                B1             = [double]$sapCust.B1
                B2             = [double]$sapCust.B2
                B3             = [double]$sapCust.B3
                B4             = [double]$sapCust.B4
                OverdueFrom    = $termsFrom
                OverdueTo      = $termsTo
                OverdueDays    = $sapCust.OverdueDays
                Terms          = $sapCust.PaymentTerms
            })
        }

        # Coded ERPNext customers whose code is NOT in the SAP book.
        $erpCodesNoSap = New-Object System.Collections.Generic.List[string]
        foreach ($k in $erpIndex.Keys) {
            if (-not $erpIndex[$k].Matched) { $erpCodesNoSap.Add($k) }
        }

        # ---- 4. Report BEFORE changing anything ----
        Write-Log INFO "---- planned changes ----"
        Write-Log INFO ("customers with at least one field to change: {0}  (credit-limit: {1} | outstanding-balance: {2})" -f `
            $plannedWrites.Count, $limitChangeCount, $balChangeCount)
        Write-Log INFO ("payment terms: {0} matched customer(s) overdue past their terms right now; {1} overdue figure(s) to change{2}." -f `
            $overdueNow, $termsChangeCount, $(if ($script:TermsFieldsReady) { '' } else { ' (fields not on ERPNext yet - nothing written)' }))
        foreach ($w in ($plannedWrites | Select-Object -First 200)) {
            $nm = $w.Name; if ($nm.Length -gt 34) { $nm = $nm.Substring(0, 34) }
            $parts = New-Object System.Collections.Generic.List[string]
            if ($null -ne $w.LimitTo) { $parts.Add(("limit {0:N2}->{1:N2}" -f $w.LimitFrom, $w.LimitTo)) }
            if ($null -ne $w.BalTo)   { $parts.Add(("bal {0:N2}->{1:N2}"   -f $w.BalFrom,   $w.BalTo)) }
            if ($w.BucketsChanged)    { $parts.Add(("buckets [{0:N0}/{1:N0}/{2:N0}/{3:N0}]" -f $w.B1, $w.B2, $w.B3, $w.B4)) }
            if ($null -ne $w.OverdueTo) { $parts.Add(("overdue past {0} {1:N0}->{2:N0} ({3}d)" -f $(if ($w.Terms) { $w.Terms } else { 'terms' }), $w.OverdueFrom, $w.OverdueTo, $w.OverdueDays)) }
            Write-Log INFO ("  {0,-10} {1,-34}  {2}" -f $w.Code, $nm, ($parts -join ' | '))
        }
        if ($plannedWrites.Count -gt 200) {
            Write-Log INFO ("  ... and {0} more" -f ($plannedWrites.Count - 200))
        }

        Write-Log INFO ("{0} coded ERPNext customer(s) are NOT in the {1} database -> LEFT UNTOUCHED on purpose (no field written, no 0, no stamp). 'Not in {1}' means 'no information'." -f $erpCodesNoSap.Count, $companyName)
        if ($sapNoFigure.Count -gt 0) {
            Write-Log INFO ("{0} matched customer(s) have a SAP CreditLimit of 0 (no figure) -> credit limit left as-is (outstanding still synced)." -f $sapNoFigure.Count)
        }
        if ($syncOutstanding -and -not $arAvailable) {
            Write-Log WARN "open-document read was unavailable - the four bucket fields were NOT evaluated or written this run."
        }
        if ($nonStandardCodes.Count -gt 0) {
            Write-Log WARN ("non-standard SAP code(s) - verify by hand: {0}" -f ($nonStandardCodes -join ', '))
        }
        if ($skippedByConfig.Count -gt 0) {
            Write-Log WARN ("SAP code(s) skipped via config.skip_codes: {0}" -f ($skippedByConfig -join ', '))
        }

        # ---- 5. Apply ----
        $changed       = 0
        $writeFailures = 0

        if ($DryRun) {
            Write-Log INFO ("DRY RUN - nothing written ({0} customer write(s) would have been made)." -f $plannedWrites.Count)
        } else {
            $toProcess = $plannedWrites
            if ($Limit -gt 0 -and $plannedWrites.Count -gt $Limit) {
                $toProcess = @($plannedWrites | Select-Object -First $Limit)
                Write-Log WARN ("-Limit {0}: applying {0} of {1} planned customer write(s) this run." -f $Limit, $plannedWrites.Count)
            }
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'   # machine local time; see README timezone note
            foreach ($w in $toProcess) {
                try {
                    # Frappe does a partial update: only the named fields change.
                    # The standard `credit_limits` child table is never named.
                    $body = $w.Fields.Clone()
                    $body[$script:F_STAMP] = $stamp
                    $null = Invoke-ErpApi -Method 'PUT' `
                        -Path ('/api/resource/Customer/' + [uri]::EscapeDataString($w.Name)) `
                        -Body $body
                    $changed++
                    Write-Log INFO ("wrote {0,-10} {1}: {2}" -f $w.Code, $w.Name, (($w.Fields.Keys | Sort-Object) -join ', '))
                } catch {
                    $writeFailures++
                    Write-Log ERROR ("write FAILED {0} {1}: {2}" -f $w.Code, $w.Name, $_)
                }
            }
        }

        # ---- 6. One-line summary ----
        $matched = @($erpIndex.Values | Where-Object { $_.Matched }).Count
        if ($DryRun) { $changeWord = 'would-change'; $changeCount = $plannedWrites.Count; $modeWord = 'DRY-RUN' }
        else         { $changeWord = 'changed';      $changeCount = $changed;             $modeWord = 'APPLIED' }

        $summaryLine = ("SUMMARY | company: {0} | SAP rows: {1} | ERPNext coded: {2} | matched: {3} | in ERPNext not in {0}: {4} | SAP code not in ERPNext: {5} | limit-0 skipped: {6} | limit changes: {7} | balance changes: {8} | buckets: {9} | customers {10}: {11} | {12} | failures: {13}" -f `
            $companyName, $sapByCode.Count, $erpIndex.Count, $matched, $erpCodesNoSap.Count, `
            $sapCodesNoErp.Count, $sapNoFigure.Count, $limitChangeCount, $balChangeCount, `
            ($(if ($writeBuckets) { 'written' } else { 'skipped' })), $changeWord, $changeCount, $modeWord, $writeFailures)
        Write-Log INFO $summaryLine

        $script:Result.company          = $companyName
        $script:Result.sapRows          = $sapByCode.Count
        $script:Result.matched          = $matched
        $script:Result.limitChanges     = $limitChangeCount
        $script:Result.balanceChanges   = $balChangeCount
        $script:Result.bucketsWritten   = [bool]$writeBuckets
        $script:Result.customersChanged = $changeCount
        $script:Result.failures         = $writeFailures
        $script:Result.summary          = $summaryLine

        if ($sapCodesNoErp.Count -gt 0) {
            Write-Log INFO ("SAP codes with no ERPNext customer ({0}): {1}" -f $sapCodesNoErp.Count, ($sapCodesNoErp -join ', '))
        }
        if ($erpCodesNoSap.Count -gt 0) {
            Write-Log INFO ("coded ERPNext customers not in {0} - untouched ({1}): {2}" -f $companyName, $erpCodesNoSap.Count, ($erpCodesNoSap -join ', '))
        }

        if ($writeFailures -gt 0) {
            $exitCode = 1
            Write-Log ERROR ("run finished WITH {0} write failure(s)." -f $writeFailures)
        } else {
            Write-Log INFO "run finished clean."
        }
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
    try {
        Write-Log INFO ("==== run end ==== elapsed {0:n1}s exit {1}" -f ((Get-Date) - $script:StartedAt).TotalSeconds, $exitCode)
    } catch { }
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

# Non-zero exit so the Scheduled Task shows failed instead of silently succeeding.
exit $exitCode
