<#
.SYNOPSIS
  Proves PASS K - ERPNext pick lists sent to Hi-Tech's SAP as pick lists, and
  B1if's invoice, goods receipt and delivery written back (stage 4, 5 Nov 2026).

.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapOrders.ps1 by AST (its
  main body never runs) and calls the SAME functions PASS K calls. Nothing is
  read or written: no SAP, no ERPNext.

  The parts:
    * order_flow.pick_lists_since: absent is off, a bad date is refused;
    * which lists are sent, left alone, waited on or refused;
    * the plan: each product on the line of Hi-Tech's order for its item,
      released for its kilos, and what refuses the whole list;
    * the POST body and the Remarks B1if reads the list's name from;
    * adopting a list a crashed run made, and refusing two;
    * what is written back from B1if's documents.

.EXAMPLE
  .\Test-PickLists.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$syncPath = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
if (-not (Test-Path $syncPath)) { throw "Cannot find $syncPath" }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

# What the script's main body sets and these functions read.
$script:F_SO = 'custom_sap_sales_order'
$SAP_BASETYPE_SALESORDER = 17

$script:pass = 0
$script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}
function Throws { param([scriptblock] $Block) try { & $Block; return $false } catch { return $true } }
function Cfg { param([string] $Json) return ($Json | ConvertFrom-Json) }
function J { param([string] $Json) return ($Json | ConvertFrom-Json) }

$flow = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","pick_lists_since":"2026-11-05"}}')

# ------------------------------------------------------------------------------
Write-Host "`norder_flow.pick_lists_since" -ForegroundColor Cyan
Check 'pick lists are off when pick_lists_since is absent' ((Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03"}}')).PickListsSince -eq '')
Check 'pick_lists_since is read' ($flow.PickListsSince -eq '2026-11-05') $flow.PickListsSince
Check 'a pick_lists_since that is not yyyy-MM-dd is refused' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","pick_lists_since":"5/11/2026"}}') })

# ------------------------------------------------------------------------------
Write-Host "`nwhich lists are sent" -ForegroundColor Cyan
$order = J '{"name":"SAL-ORD-2026-00167","creation":"2026-11-05 12:19:00","custom_company":"Manna Treads","docstatus":0,"custom_sap_sales_order":"555",
  "items":[{"name":"r0","item_code":"PMB00101002"},{"name":"r1","item_code":"PMB00101502"}]}'
$pick = J '{"name":"PICK-00012","status":"Submitted","approval_status":"Approved","sales_order":"SAL-ORD-2026-00167","sap_pick_list":"","sap_sync_error":"",
  "items":[{"sales_order_item":"r1","item_code":"PMB00101502","item_name":"PCTR 197","picked_qty":1,"picked_kg":31.4}]}'
function Pk { param([hashtable] $Set = @{}) $o = $pick | ConvertTo-Json -Depth 5 | ConvertFrom-Json; foreach ($k in $Set.Keys) { $o.$k = $Set[$k] }; return $o }
function Od { param([hashtable] $Set = @{}) $o = $order | ConvertTo-Json -Depth 5 | ConvertFrom-Json; foreach ($k in $Set.Keys) { $o.$k = $Set[$k] }; return $o }

$r = Get-PkSkipReason -Pick $pick -Order $order -Flow $flow
Check 'a Submitted list with kilos, on a manna_first order with Hi-Tech''s order, is sent' ($r.Kind -eq '') "$($r.Kind) $($r.Why)"
Check 'a cancelled list is left alone' ((Get-PkSkipReason -Pick (Pk @{ status = 'Cancelled' }) -Order $order -Flow $flow).Kind -eq 'skip')
Check 'a list already in SAP is not sent again' ((Get-PkSkipReason -Pick (Pk @{ sap_pick_list = '7' }) -Order $order -Flow $flow).Kind -eq 'skip')
Check 'a list with an error on it waits for somebody to clear it' ((Get-PkSkipReason -Pick (Pk @{ sap_sync_error = 'x' }) -Order $order -Flow $flow).Kind -eq 'skip')
Check 'a list on an order of the old route is left to Hi-Tech by hand' ((Get-PkSkipReason -Pick $pick -Order (Od @{ creation = '2026-10-30 10:00:00' }) -Flow $flow).Kind -eq 'skip')
Check 'a list whose order has no Hi-Tech order yet waits' ((Get-PkSkipReason -Pick $pick -Order (Od @{ custom_sap_sales_order = '' }) -Flow $flow).Kind -eq 'wait')
Check 'a list on a cancelled order is refused' ((Get-PkSkipReason -Pick $pick -Order (Od @{ docstatus = 2 }) -Flow $flow).Kind -eq 'refuse')
Check 'a list whose order is gone is refused' ((Get-PkSkipReason -Pick $pick -Order $null -Flow $flow).Kind -eq 'refuse')
# No approval (7 Nov 2026): approval_status no longer decides anything.
$r = Get-PkSkipReason -Pick (Pk @{ approval_status = 'Pending' }) -Order $order -Flow $flow
Check 'a Pending list is sent - lists are not approved any more' ($r.Kind -eq '') "$($r.Kind) $($r.Why)"
Check 'a list with a blank approval is sent' ((Get-PkSkipReason -Pick (Pk @{ approval_status = '' }) -Order $order -Flow $flow).Kind -eq '')
$bare = $pick | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $bare.PSObject.Properties.Remove('approval_status')
Check 'a site without the approval field sends it too' ((Get-PkSkipReason -Pick $bare -Order $order -Flow $flow).Kind -eq '')
Check 'a Pending list on a cancelled order is refused, like any other' ((Get-PkSkipReason -Pick (Pk @{ approval_status = 'Pending' }) -Order (Od @{ docstatus = 2 }) -Flow $flow).Kind -eq 'refuse')
$noKg = J '{"name":"PICK-00009","status":"Submitted","approval_status":"Approved","sap_pick_list":"","sap_sync_error":"","items":[{"sales_order_item":"r1","item_name":"PCTR 197","picked_qty":1}]}'
$r = Get-PkSkipReason -Pick $noKg -Order $order -Flow $flow
Check 'a list made before kilos were asked for is refused, naming the product' ($r.Kind -eq 'refuse' -and $r.Why -match 'PCTR 197') $r.Why

# ------------------------------------------------------------------------------
Write-Host "`nthe plan" -ForegroundColor Cyan
$ht = J '{"DocEntry":3040,"DocNum":555,"DocumentLines":[{"LineNum":0,"ItemCode":"PMB00101002","LineStatus":"bost_Open"},{"LineNum":1,"ItemCode":"PMB00101502","LineStatus":"bost_Open"}]}'
$plan = Get-PkPlan -Pick $pick -Order $order -HtOrder $ht
$l = @($plan.Lines)[0]
Check 'a product goes on the line of Hi-Tech''s order for its item' ($plan.Problems.Count -eq 0 -and $plan.Lines.Count -eq 1 -and $l.OrderEntry -eq 3040 -and $l.OrderRowID -eq 1) (($plan.Problems) -join '; ')
Check 'it is released for the weighed kilos, not the rolls' ($l.ReleasedQuantity -eq 31.4) "$($l.ReleasedQuantity)"
Check 'it is based on a sales order (17)' ($l.BaseObjectType -eq 17)
Check 'a product left off the list is not on the SAP pick list - that is how an item is cancelled' (@($plan.Lines | Where-Object { $_.OrderRowID -eq 0 }).Count -eq 0)
$p2 = Pk @{ items = @((J '{"sales_order_item":"r0","item_code":"PMB00101002","picked_qty":2,"picked_kg":48.6}'), (J '{"sales_order_item":"r1","item_code":"PMB00101502","picked_qty":1,"picked_kg":31.4}')) }
$plan2 = Get-PkPlan -Pick $p2 -Order $order -HtOrder $ht
Check 'two products, two lines, each on its own row' ($plan2.Lines.Count -eq 2 -and (@($plan2.Lines | ForEach-Object { $_.OrderRowID }) -join ',') -eq '0,1')
$htClosed = J '{"DocEntry":3040,"DocNum":555,"DocumentLines":[{"LineNum":0,"ItemCode":"PMB00101002","LineStatus":"bost_Open"},{"LineNum":1,"ItemCode":"PMB00101502","LineStatus":"bost_Close"}]}'
Check 'a product already closed on Hi-Tech''s order refuses the list' ((Get-PkPlan -Pick $pick -Order $order -HtOrder $htClosed).Problems.Count -eq 1)
$htMissing = J '{"DocEntry":3040,"DocNum":555,"DocumentLines":[{"LineNum":0,"ItemCode":"PMB00101002","LineStatus":"bost_Open"}]}'
$pm = Get-PkPlan -Pick $p2 -Order $order -HtOrder $htMissing
Check 'a product not on Hi-Tech''s order refuses the WHOLE list, not just that line' ($pm.Problems.Count -eq 1 -and @($pm.Problems)[0] -match 'PMB00101502') (($pm.Problems) -join '; ')
$htTwice = J '{"DocEntry":3040,"DocNum":555,"DocumentLines":[{"LineNum":0,"ItemCode":"PMB00101502","LineStatus":"bost_Open"},{"LineNum":1,"ItemCode":"PMB00101502","LineStatus":"bost_Open"}]}'
Check 'an item on two lines of Hi-Tech''s order is refused rather than guessed' ((Get-PkPlan -Pick $pick -Order $order -HtOrder $htTwice).Problems.Count -eq 1)
$foreign = Pk @{ items = @((J '{"sales_order_item":"zz","item_code":"","picked_qty":1,"picked_kg":5}')) }
Check 'a product that is not on the order is refused' ((Get-PkPlan -Pick $foreign -Order $order -HtOrder $ht).Problems.Count -eq 1)
$codeLow = J '{"DocEntry":3040,"DocNum":555,"DocumentLines":[{"LineNum":4,"ItemCode":"pmb00101502","LineStatus":"bost_Open"}]}'
Check 'item codes match whatever their case' (@((Get-PkPlan -Pick $pick -Order $order -HtOrder $codeLow).Lines)[0].OrderRowID -eq 4)

# ------------------------------------------------------------------------------
Write-Host "`nthe POST body" -ForegroundColor Cyan
$b = New-PkBody -Plan $plan -PickName 'PICK-00012' -OrderName 'SAL-ORD-2026-00167' -Today '2026-11-05'
Check 'Remarks start "ERPNext <list> - order <order>", which B1if reads the list''s name from' ($b.Remarks -eq 'ERPNext PICK-00012 - order SAL-ORD-2026-00167') $b.Remarks
Check 'PickDate is today' ($b.PickDate -eq '2026-11-05')
$json = $b | ConvertTo-Json -Depth 6 -Compress
Check 'the body serialises with its lines' ($json -match '"PickListsLines":\[\{"BaseObjectType":17,"OrderEntry":3040,"OrderRowID":1,"ReleasedQuantity":31.4\}\]') $json

# ------------------------------------------------------------------------------
Write-Host "`nadopting a list a crashed run made" -ForegroundColor Cyan
$hits = @((J '{"Absoluteentry":7,"Remarks":"ERPNext PICK-00012 - order SAL-ORD-2026-00167"}'), (J '{"Absoluteentry":8,"Remarks":"ERPNext PICK-000123 - order X"}'), (J '{"Absoluteentry":2,"Remarks":"PROBE"}'))
$a = Select-PkAdoptable -Hits $hits -PickName 'PICK-00012'
Check 'the list''s own SAP pick list is adopted' ("$($a.Adopt.Absoluteentry)" -eq '7') "$($a.Adopt.Absoluteentry)"
Check 'PICK-000123 is not mistaken for PICK-00012' ("$((Select-PkAdoptable -Hits $hits -PickName 'PICK-000123').Adopt.Absoluteentry)" -eq '8')
Check 'none found is nothing to adopt' ($null -eq (Select-PkAdoptable -Hits @() -PickName 'PICK-00012').Adopt)
$two = Select-PkAdoptable -Hits @($hits[0], (J '{"Absoluteentry":9,"Remarks":"ERPNext PICK-00012 - order SAL-ORD-2026-00167"}')) -PickName 'PICK-00012'
Check 'two SAP pick lists for one list are refused - they would invoice twice' ($null -eq $two.Adopt -and $two.Error -match 'duplicate') $two.Error

# ------------------------------------------------------------------------------
Write-Host "`nwhat is written back" -ForegroundColor Cyan
$row = J '{"name":"PICK-00012","sap_pick_list":"7","hitech_invoice":"","mt_goods_receipt":"","mt_delivery":""}'
$inv = @(J '{"DocNum":490,"Cancelled":"tNO"}'); $grpo = @(J '{"DocNum":249,"Cancelled":"tNO"}'); $dn = @(J '{"DocNum":2,"Cancelled":"tNO"}')
$w = Get-PkLinkWrites -Pick $row -Invoices $inv -Receipts $grpo -Deliveries $dn
Check 'all three found: all three written, and the list is complete' ($w.Complete -and $w.Fields.hitech_invoice -eq '490' -and $w.Fields.mt_goods_receipt -eq '249' -and $w.Fields.mt_delivery -eq '2')
$w = Get-PkLinkWrites -Pick $row -Invoices @() -Receipts @() -Deliveries @()
Check 'none yet: nothing written, not complete' (-not $w.Complete -and $w.Fields.Count -eq 0 -and $w.Error -eq '')
$w = Get-PkLinkWrites -Pick $row -Invoices @((J '{"DocNum":490,"Cancelled":"tYES"}')) -Receipts $grpo -Deliveries $dn
Check 'a cancelled invoice is not the list''s invoice' (-not $w.Complete -and -not $w.Fields.ContainsKey('hitech_invoice'))
$w = Get-PkLinkWrites -Pick (J '{"hitech_invoice":"490","mt_goods_receipt":"249","mt_delivery":""}') -Invoices $inv -Receipts $grpo -Deliveries $dn
Check 'only what is new is written' ($w.Complete -and $w.Fields.Count -eq 1 -and $w.Fields.mt_delivery -eq '2')
$w = Get-PkLinkWrites -Pick $row -Invoices $inv -Receipts @((J '{"DocNum":249,"Cancelled":"tNO"}'), (J '{"DocNum":250,"Cancelled":"tNO"}')) -Deliveries $dn
Check 'two live goods receipts for one list are a duplicate, said and not written' ($w.Error -match 'duplicate' -and $w.Fields.Count -eq 0) $w.Error

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
