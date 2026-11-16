<#
.SYNOPSIS
  Temporary credit extensions (16 Nov 2026): raise a customer's SAP credit
  limit for an approved extension, count the customer's confirmed SAP payments
  against the payment commitment, and put the original limit back.

.DESCRIPTION
  A SEPARATE job beside Sync-SapCreditLimits.ps1, which it does not change: it
  borrows that script's functions (SAP login with the pinned certificate,
  paging, ERPNext calls, the TEST/local pairing guard) by reading them out of
  the file, the way Test-InvoiceMirror.ps1 does, and runs none of its body.
  It reads the same config.json.

  Each run, in this order, in ONE Service Layer session (only opened when
  there is something to do):

    1. RESTORE  every extension whose restore_status is Pending (Paid or
                Payment Commitment Overdue): SAP CreditLimit back to the
                original, with the commitment limit (MaxCommitment) the raise
                lifted alongside it - only while SAP still holds what the
                raise wrote; any other figure is somebody's newer change and
                is reported 'Needs Review', never overwritten. SAP refuses a
                credit limit above the commitment limit, so they move together.
    2. RAISE    every extension 'Sending to SAP': original + amount, the
                original saved in ERPNext before the write so a retry knows
                it. Refused while another extension of the customer is still
                raised, if SAP's limit is 0 (no figure), or if SAP's limit
                moved since the first attempt. Read back after writing.
    3. PAYMENTS every 'Active' extension: SAP incoming payments for the
                customer dated from the approval to the commitment date, not
                cancelled, not drafts, each counted once by DocEntry. The
                Server Script decides Paid / still running / Payment
                Commitment Overdue (escalated to the GM) from them - and a
                second RESTORE pass follows for any that just finished.

  Every SAP request and response is written to the extension's SAP log.
  shared/fixtures/credit_extension.json (payments, sap_raise, sap_restore)
  pins the decisions; Test-CreditExtensions.ps1 runs them offline.

  Writes nothing - to SAP or ERPNext - without -Apply.

.PARAMETER ConfigPath
  The credit sync's config.json (erpnext + sap sections; one company).

.PARAMETER Apply
  Make the changes. Without it the run reads and logs what it would do.

.PARAMETER PaymentCheckMinutes
  An Active extension's payments are read at most this often (default 60),
  except on or after its commitment date or when an approval asked for a run.
  Keeps the Service Layer's few licence seats free.

.EXAMPLE
  .\Sync-CreditExtensions.ps1 -ConfigPath .\config.json            # dry run
  .\Sync-CreditExtensions.ps1 -ConfigPath .\config.json -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ConfigPath,
    [switch] $Apply,
    [int] $PaymentCheckMinutes = 60
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---- the credit sync's own functions, its body never run ----
$syncPath = Join-Path $PSScriptRoot 'Sync-SapCreditLimits.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

$script:LogFile     = $null
$script:SapSkipCert = $false
$script:XT          = 'Manna Credit Extension'
$script:XS          = 'Manna Credit Extension Settings'

# --------------------------------------------------------------------------------
# Decisions (pure; Test-CreditExtensions.ps1)
# --------------------------------------------------------------------------------

function Get-IsoDay { param($Value) $s = "$Value"; if ($s.Length -ge 10) { return $s.Substring(0, 10) } return $s }

function Get-PaymentAmount {
    # What one SAP incoming payment brought in: cash, transfer, bills of
    # exchange, every cheque and every card line. SAP has no single total.
    param($Payment)
    $sum = [double](ConvertTo-Number (Get-JsonProp $Payment 'CashSum')) +
           [double](ConvertTo-Number (Get-JsonProp $Payment 'TransferSum')) +
           [double](ConvertTo-Number (Get-JsonProp $Payment 'BillOfExchangeAmount'))
    foreach ($c in @(Get-JsonProp $Payment 'PaymentChecks')) { if ($c) { $sum += [double](ConvertTo-Number (Get-JsonProp $c 'CheckSum')) } }
    foreach ($c in @(Get-JsonProp $Payment 'PaymentCreditCards')) { if ($c) { $sum += [double](ConvertTo-Number (Get-JsonProp $c 'CreditSum')) } }
    return [math]::Round($sum, 2)
}

function Get-CountedPayments {
    # The confirmed payments that count against a commitment: dated from the
    # approval day to the commitment day, not cancelled, not a draft, once each.
    param([object[]] $Payments, [string] $From, [string] $To)
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Payments)) {
        if (-not $p) { continue }
        $entry = "$(Get-JsonProp $p 'DocEntry')"
        if ($seen.ContainsKey($entry)) { continue }
        if ("$(Get-JsonProp $p 'Cancelled')" -eq 'tYES') { continue }
        if ("$(Get-JsonProp $p 'Proforma')" -eq 'tYES') { continue }
        $day = Get-IsoDay (Get-JsonProp $p 'DocDate')
        if ($day -lt (Get-IsoDay $From) -or $day -gt (Get-IsoDay $To)) { continue }
        $amt = Get-PaymentAmount $p
        if ($amt -le 0) { continue }
        $seen[$entry] = $true
        $out.Add([ordered]@{ doc_entry = $entry; doc_num = "$(Get-JsonProp $p 'DocNum')"; date = $day; amount = $amt })
    }
    return , $out.ToArray()
}

function Get-ExtensionRaisePlan {
    # patch | already | refuse | skip, with the original and target credit and
    # commitment limits. SAP refuses a credit limit above the commitment limit
    # (MaxCommitment, OCRD.DebtLine), and on TEST every customer has the two
    # equal (16 Nov 2026), so the commitment limit goes up to at least the new
    # credit limit in the same write - and is never overwritten if somebody
    # changed it, exactly like the credit limit.
    param([string] $Status, $SavedOriginal, [double] $SapLimit, [double] $Amount, [bool] $OtherRaised,
          $SavedCommitment = $null, [double] $SapCommitment = 0)
    if ($Status -ne 'Sending to SAP') { return @{ Action = 'skip'; Reason = "status is '$Status'" } }
    if ($OtherRaised) { return @{ Action = 'refuse'; Reason = 'another temporary extension of this customer is still raised in SAP' } }
    if ($Amount -le 0) { return @{ Action = 'refuse'; Reason = 'no amount approved' } }
    $hasSaved = ($null -ne $SavedOriginal -and "$SavedOriginal" -ne '' -and [double]$SavedOriginal -gt 0)
    $original = if ($hasSaved) { [double]$SavedOriginal } else { $SapLimit }
    $hasSavedC = ($null -ne $SavedCommitment -and "$SavedCommitment" -ne '' -and [double]$SavedCommitment -gt 0)
    $origC = if ($hasSavedC) { [double]$SavedCommitment } else { $SapCommitment }
    $target = [math]::Round($original + $Amount, 2)
    $targetC = [math]::Max($origC, $target)
    $plan = @{ Original = $original; Target = $target; OriginalCommitment = $origC; CommitmentTarget = $targetC }
    if ($original -le 0) { return @{ Action = 'refuse'; Reason = 'SAP holds no credit limit for this customer (0) - raising it would invent one' } }
    if ([math]::Abs($SapLimit - $target) -lt 0.005 -and [math]::Abs($SapCommitment - $targetC) -lt 0.005) {
        return $plan + @{ Action = 'already'; Reason = "SAP already holds $target (commitment $targetC)" }
    }
    if ([math]::Abs($SapLimit - $original) -ge 0.005) {
        return @{ Action = 'refuse'; Reason = "SAP's credit limit is $SapLimit, not the original $original or the raised $target - changed by somebody since; not overwritten" }
    }
    if ([math]::Abs($SapCommitment - $origC) -ge 0.005) {
        return @{ Action = 'refuse'; Reason = "SAP's commitment limit is $SapCommitment, not the original $origC - changed by somebody since; not overwritten" }
    }
    return $plan + @{ Action = 'patch'; Reason = "$original -> $target (commitment $origC -> $targetC)" }
}

function Get-ExtensionRestorePlan {
    # patch | already | review: both figures back, only from what the raise wrote.
    param([double] $Original, [double] $Amount, [double] $SapLimit,
          [double] $OriginalCommitment = 0, [double] $RaisedCommitment = 0, [double] $SapCommitment = 0)
    $raised = [math]::Round($Original + $Amount, 2)
    $limitIsOriginal = [math]::Abs($SapLimit - $Original) -lt 0.005
    $commitIsOriginal = [math]::Abs($SapCommitment - $OriginalCommitment) -lt 0.005
    $limitIsRaised = [math]::Abs($SapLimit - $raised) -lt 0.005
    $commitIsRaised = [math]::Abs($SapCommitment - $RaisedCommitment) -lt 0.005
    if ($limitIsOriginal -and $commitIsOriginal) {
        return @{ Action = 'already'; Reason = "SAP already holds the original $Original (commitment $OriginalCommitment)" }
    }
    if ($limitIsRaised -and $commitIsRaised) {
        return @{ Action = 'patch'; Reason = "$raised -> $Original (commitment $RaisedCommitment -> $OriginalCommitment)" }
    }
    return @{ Action = 'review'; Reason = "SAP holds credit limit $SapLimit and commitment limit $SapCommitment, not what the raise wrote ($raised / $RaisedCommitment) nor the originals ($Original / $OriginalCommitment) - somebody changed them; left as they are" }
}

# --------------------------------------------------------------------------------
# ERPNext and SAP calls
# --------------------------------------------------------------------------------

function Get-ErpExtensions {
    param([string] $FiltersJson)
    $fields = '["name","status","customer","bp_code","amount","commitment_date","approved_on","original_limit","raised_limit","original_commitment","raised_commitment","sap_raised","restore_status","last_payment_check"]'
    $q = 'fields=' + [uri]::EscapeDataString($fields) + '&filters=' + [uri]::EscapeDataString($FiltersJson) + '&limit_page_length=0'
    $resp = Invoke-ErpApi -Method 'GET' -Path ('/api/resource/' + [uri]::EscapeDataString($script:XT)) -Query $q
    return , @($resp.data)
}

function Send-ExtensionEvent {
    param([string] $Name, [string] $EventName, [hashtable] $Data = @{})
    $body = @{ action = 'sap_event'; name = $Name; event = $EventName }
    foreach ($k in $Data.Keys) { $body[$k] = $Data[$k] }
    return (Invoke-ErpApi -Method 'POST' -Path '/api/method/manna_credit_extension' -Body $body).message
}

function Invoke-Sl {
    # One Service Layer call; returns @{ Ok; Body; Text } and never throws, so
    # every request and answer can go to the extension's SAP log.
    param([string] $Method, [string] $Url, $Session, $Body = $null)
    $splat = @{ Method = $Method; Uri = $Url; WebSession = $Session; ErrorAction = 'Stop'; TimeoutSec = 90 }
    if ($null -ne $Body) { $splat.Body = ($Body | ConvertTo-Json -Compress -Depth 4); $splat.ContentType = 'application/json' }
    if ($script:UseSkip) { $splat.SkipCertificateCheck = $true }
    try {
        $r = Invoke-RestMethod @splat
        $t = if ($null -eq $r) { '(204 no content)' } else { ($r | ConvertTo-Json -Compress -Depth 4) }
        return @{ Ok = $true; Body = $r; Text = $t }
    } catch {
        return @{ Ok = $false; Body = $null; Text = (Format-HttpError $_ "SAP $Method") }
    }
}

function Get-SapBp {
    param([string] $BaseUrl, $Session, [string] $Card)
    $key = [uri]::EscapeDataString(($Card -replace "'", "''"))
    return Invoke-Sl -Method 'Get' -Url "$BaseUrl/BusinessPartners('$key')?`$select=CardCode,CreditLimit,MaxCommitment,UpdateDate,UpdateTime" -Session $Session
}

function Set-SapLimit {
    # Both figures in ONE write: SAP checks the commitment limit against the
    # credit limit as it saves, so they move together or not at all.
    param([string] $BaseUrl, $Session, [string] $Card, [double] $Limit, [double] $Commitment)
    $key = [uri]::EscapeDataString(($Card -replace "'", "''"))
    return Invoke-Sl -Method 'Patch' -Url "$BaseUrl/BusinessPartners('$key')" -Session $Session -Body @{ CreditLimit = $Limit; MaxCommitment = $Commitment }
}

function Get-SapRef {
    param([string] $Db, [string] $Card, $Bp, [double] $From, [double] $To)
    return ('{0}/{1} CreditLimit {2} -> {3}, MaxCommitment {4} @ {5} {6}' -f $Db, $Card, $From, $To, (Get-JsonProp $Bp 'MaxCommitment'), (Get-IsoDay (Get-JsonProp $Bp 'UpdateDate')), (Get-JsonProp $Bp 'UpdateTime'))
}

function Invoke-Restore {
    param($X, [string] $BaseUrl, $Session, [string] $Db)
    $name = "$($X.name)"; $card = "$($X.bp_code)"
    $orig = [double](ConvertTo-Number $X.original_limit); $amt = [double](ConvertTo-Number $X.amount)
    $bp = Get-SapBp -BaseUrl $BaseUrl -Session $Session -Card $card
    if (-not $bp.Ok) { Write-Log ERROR ("{0}: restore - SAP read failed, tried again next run: {1}" -f $name, $bp.Text); return }
    $now = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'CreditLimit'))
    $nowC = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'MaxCommitment'))
    $origC = [double](ConvertTo-Number $X.original_commitment); $raisedC = [double](ConvertTo-Number $X.raised_commitment)
    if ($origC -le 0) { $origC = $nowC; $raisedC = $nowC }
    $plan = Get-ExtensionRestorePlan -Original $orig -Amount $amt -SapLimit $now -OriginalCommitment $origC -RaisedCommitment $raisedC -SapCommitment $nowC
    if (-not $Apply) { Write-Log INFO ("{0}: would restore - {1} [dry run]" -f $name, $plan.Reason); return }
    if ($plan.Action -eq 'review') {
        Write-Log WARN ("{0}: restore needs review - {1}" -f $name, $plan.Reason)
        $null = Send-ExtensionEvent $name 'review' @{ error = $plan.Reason; request = "GET $card"; response = $bp.Text }
        return
    }
    if ($plan.Action -eq 'patch') {
        $w = Set-SapLimit -BaseUrl $BaseUrl -Session $Session -Card $card -Limit $orig -Commitment $origC
        if (-not $w.Ok) { Write-Log ERROR ("{0}: restore refused by SAP, tried again next run: {1}" -f $name, $w.Text); return }
        $bp = Get-SapBp -BaseUrl $BaseUrl -Session $Session -Card $card
        $after = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'CreditLimit'))
        $afterC = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'MaxCommitment'))
        if ([math]::Abs($after - $orig) -ge 0.005 -or [math]::Abs($afterC - $origC) -ge 0.005) { Write-Log ERROR ("{0}: SAP accepted the restore but reads {1}, not {2}; tried again next run" -f $name, $after, $orig); return }
    }
    $ref = Get-SapRef $Db $card $bp.Body $now $orig
    $null = Send-ExtensionEvent $name 'restored' @{ sap_reference = $ref; request = ("PATCH BusinessPartners('{0}') CreditLimit={1} MaxCommitment={2}" -f $card, $orig, $origC); response = $bp.Text }
    Write-Log INFO ("{0}: restored - {1}" -f $name, $ref)
}

# --------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------

$exitCode = 0
$summary = ''
try {
    $config = Read-JsonConfig -Path $ConfigPath
    $erp = Get-JsonProp $config 'erpnext'
    $script:ErpBaseUrl = Get-RequiredString $erp 'site' 'erpnext'
    $script:ErpAuthHeader = 'token {0}:{1}' -f (Get-RequiredString $erp 'api_key' 'erpnext'), (Get-RequiredString $erp 'api_secret' 'erpnext')
    $sap = Get-JsonProp $config 'sap'
    $sapUrl = (Get-RequiredString $sap 'url' 'sap').TrimEnd('/')
    $companies = @(Get-JsonProp $sap 'companies')
    if ($companies.Count -ne 1) { throw 'config: sap.companies must contain exactly ONE entry.' }
    $db = Get-RequiredString $companies[0] 'company_db' 'sap.companies[0]'
    $companyName = Get-RequiredString $companies[0] 'name' 'sap.companies[0]'
    Assert-SapErpPairing -ErpSite $script:ErpBaseUrl -CompanyDbs @($db)
    $logDir = Join-Path $PSScriptRoot 'logs'
    $ld = Get-JsonProp $config 'log_dir'
    if ($ld) { $logDir = "$ld" }
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LogFile = Join-Path $logDir ('credit-extensions-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    Write-Log INFO ("==== credit extensions ==== db='{0}' Apply={1}" -f $db, [bool]$Apply)

    $verifySsl = $true
    $vp = $sap.PSObject.Properties['verify_ssl']; if ($vp) { $verifySsl = [bool]$vp.Value }
    $script:SapSkipCert = (-not $verifySsl)
    $pin = "$(Get-JsonProp $sap 'pinned_cert_sha256')" -replace '[^0-9A-Fa-f]', ''
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        if ($script:SapSkipCert) { Enable-SapCertBypass -SapHost ([System.Uri]$sapUrl).Host -PinSha256 $pin }
    } elseif ($pin) { throw 'config: sap.pinned_cert_sha256 needs Windows PowerShell 5.1.' }
    $script:UseSkip = ($script:SapSkipCert -and $PSVersionTable.PSVersion.Major -ge 6)

    # ---- the work, from ERPNext; no SAP login unless there is some ----
    try {
        $settings = (Invoke-ErpApi -Method 'GET' -Path ('/api/resource/' + [uri]::EscapeDataString($script:XS) + '/' + [uri]::EscapeDataString($script:XS))).data
    } catch {
        Write-Log WARN ("the '{0}' doctype is not on ERPNext yet - nothing to do." -f $script:XS); exit 0
    }
    $asked = ("$(Get-JsonProp $settings 'push_requested')" -eq '1')
    $restore = Get-ErpExtensions '[["restore_status","=","Pending"]]'
    $raise   = Get-ErpExtensions '[["status","=","Sending to SAP"]]'
    $active  = Get-ErpExtensions '[["status","=","Active"]]'
    $raisedNow = Get-ErpExtensions '[["sap_raised","=",1],["restore_status","!=","Restored"]]'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $dueChecks = @($active | Where-Object {
        $asked -or ((Get-IsoDay $_.commitment_date) -le $today) -or -not $_.last_payment_check -or
        (((Get-Date) - [datetime]"$($_.last_payment_check)").TotalMinutes -ge $PaymentCheckMinutes) })
    Write-Log INFO ("to restore {0}, to raise {1}, payments to check {2} of {3} active" -f $restore.Count, $raise.Count, $dueChecks.Count, $active.Count)
    if ($restore.Count + $raise.Count + $dueChecks.Count -eq 0) {
        $summary = 'nothing to do'
    } else {
        $sess = New-SapWebSession -BaseUrl $sapUrl -Username (Get-RequiredString $sap 'username' 'sap') -Password (Get-RequiredString $sap 'password' 'sap') `
            -CompanyDb $db -CompanyName $companyName -UseSkipCert $script:UseSkip
        try {
            # 1. restore
            foreach ($x in $restore) { Invoke-Restore -X $x -BaseUrl $sapUrl -Session $sess -Db $db }

            # 2. raise - after the restores, so a GM renewal follows its overdue predecessor
            $stillRaised = @{}
            if ($Apply) { $raisedNow = Get-ErpExtensions '[["sap_raised","=",1],["restore_status","!=","Restored"]]' }
            foreach ($r in $raisedNow) { $stillRaised["$($r.bp_code)|$($r.name)"] = $true }
            foreach ($x in $raise) {
                $name = "$($x.name)"; $card = "$($x.bp_code)"
                $other = [bool](@($stillRaised.Keys | Where-Object { $_ -like "$card|*" -and $_ -ne "$card|$name" }).Count)
                $bp = Get-SapBp -BaseUrl $sapUrl -Session $sess -Card $card
                if (-not $bp.Ok) {
                    Write-Log ERROR ("{0}: SAP read failed: {1}" -f $name, $bp.Text)
                    if ($Apply) { $null = Send-ExtensionEvent $name 'failed' @{ error = $bp.Text; request = "GET BusinessPartners('$card')"; response = $bp.Text } }
                    continue
                }
                $sapLimit = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'CreditLimit'))
                $sapC = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'MaxCommitment'))
                $plan = Get-ExtensionRaisePlan -Status "$($x.status)" -SavedOriginal $x.original_limit -SapLimit $sapLimit -Amount ([double](ConvertTo-Number $x.amount)) -OtherRaised $other `
                    -SavedCommitment $x.original_commitment -SapCommitment $sapC
                if (-not $Apply) { Write-Log INFO ("{0}: would {1} - {2} [dry run]" -f $name, $plan.Action, $plan.Reason); continue }
                if ($plan.Action -eq 'skip') { continue }
                if ($plan.Action -eq 'refuse') {
                    Write-Log WARN ("{0}: not raised - {1}" -f $name, $plan.Reason)
                    $null = Send-ExtensionEvent $name 'failed' @{ error = ('Not sent to SAP: ' + $plan.Reason); request = "GET BusinessPartners('$card')"; response = $bp.Text }
                    continue
                }
                if ($plan.Action -eq 'patch') {
                    $null = Send-ExtensionEvent $name 'original' @{ original_limit = $plan.Original; original_commitment = $plan.OriginalCommitment }
                    $w = Set-SapLimit -BaseUrl $sapUrl -Session $sess -Card $card -Limit $plan.Target -Commitment $plan.CommitmentTarget
                    if (-not $w.Ok) {
                        Write-Log ERROR ("{0}: SAP refused: {1}" -f $name, $w.Text)
                        $null = Send-ExtensionEvent $name 'failed' @{ error = $w.Text; request = ("PATCH BusinessPartners('{0}') CreditLimit={1} MaxCommitment={2}" -f $card, $plan.Target, $plan.CommitmentTarget); response = $w.Text }
                        continue
                    }
                    $bp = Get-SapBp -BaseUrl $sapUrl -Session $sess -Card $card
                    $after = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'CreditLimit'))
                    $afterC = [double](ConvertTo-Number (Get-JsonProp $bp.Body 'MaxCommitment'))
                    if ([math]::Abs($after - $plan.Target) -ge 0.005 -or [math]::Abs($afterC - $plan.CommitmentTarget) -ge 0.005) {
                        Write-Log ERROR ("{0}: SAP accepted but reads {1}, not {2}; tried again next run" -f $name, $after, $plan.Target)
                        continue
                    }
                }
                $ref = Get-SapRef $db $card $bp.Body $plan.Original $plan.Target
                $null = Send-ExtensionEvent $name 'raised' @{ original_limit = $plan.Original; raised_limit = $plan.Target
                    original_commitment = $plan.OriginalCommitment; raised_commitment = $plan.CommitmentTarget; sap_reference = $ref
                    request = ("PATCH BusinessPartners('{0}') CreditLimit={1} MaxCommitment={2}" -f $card, $plan.Target, $plan.CommitmentTarget); response = $bp.Text }
                $stillRaised["$card|$name"] = $true
                Write-Log INFO ("{0}: raised - {1}" -f $name, $ref)
            }

            # 3. payments, then restore whatever just finished
            foreach ($x in $dueChecks) {
                $name = "$($x.name)"; $card = "$($x.bp_code)"
                $from = Get-IsoDay $x.approved_on; $to = Get-IsoDay $x.commitment_date
                $flt = [uri]::EscapeDataString(("CardCode eq '{0}' and DocDate ge '{1}' and DocDate le '{2}'" -f ($card -replace "'", "''"), $from, $to))
                try {
                    $rows = Get-SapPagedValue -BaseUrl $sapUrl -Session $sess -PageSize 50 -UseSkipCert $script:UseSkip `
                        -Label "IncomingPayments $card" -StartUrl "$sapUrl/IncomingPayments?`$filter=$flt&`$orderby=DocEntry"
                } catch { Write-Log ERROR ("{0}: payments not read, tried again next run: {1}" -f $name, $_.Exception.Message); continue }
                $counted = Get-CountedPayments -Payments @($rows) -From $from -To $to
                $paid = ($counted | ForEach-Object { $_.amount } | Measure-Object -Sum).Sum
                if (-not $Apply) { Write-Log INFO ("{0}: {1} payment(s), {2} of {3} [dry run]" -f $name, $counted.Count, $paid, $x.amount); continue }
                $ans = Send-ExtensionEvent $name 'payments' @{ payments = ($(if ($counted.Count) { ConvertTo-Json -InputObject @($counted) -Compress } else { '[]' }))
                    request = "GET IncomingPayments $card $from..$to"; response = ("{0} payment(s), {1}" -f $counted.Count, $paid) }
                Write-Log INFO ("{0}: {1} payment(s), {2} of {3} -> {4}" -f $name, $counted.Count, $paid, $x.amount, $ans.status)
                if ("$($ans.restore_status)" -eq 'Pending') {
                    $fresh = Get-ErpExtensions ('[["name","=","' + $name + '"]]')
                    if ($fresh.Count) { Invoke-Restore -X $fresh[0] -BaseUrl $sapUrl -Session $sess -Db $db }
                }
            }
        } finally {
            try { $null = Invoke-Sl -Method 'Post' -Url "$sapUrl/Logout" -Session $sess } catch { }
        }
        $summary = ("restore {0}, raise {1}, payments {2}" -f $restore.Count, $raise.Count, $dueChecks.Count)
    }
    if ($Apply) {
        $path = '/api/resource/' + [uri]::EscapeDataString($script:XS) + '/' + [uri]::EscapeDataString($script:XS)
        $null = Invoke-ErpApi -Method 'PUT' -Path $path -Body @{ push_requested = 0; last_job_run = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); last_job_result = $summary }
    }
    Write-Log INFO ("==== done: {0}" -f $summary)
} catch {
    $exitCode = 1
    try { Write-Log ERROR ("FATAL: {0}" -f $_.Exception.Message) } catch { Write-Host "FATAL: $($_.Exception.Message)" }
}
exit $exitCode
