<#
.SYNOPSIS
  Offline checks of the B1if transforms in ..\step1-mt-po and ..\step2-ht-so.

.DESCRIPTION
  Each transform is run by .NET's XSLT 1.0 engine against a hand-made B1if
  message - the B1 event, and the SQL results as B1if hands them on
  (Payload[@id]/jdbc:ResultSet/jdbc:Row/jdbc:<column>) - and the output is
  held to the rule in the check's name. No SAP, no B1if:

      powershell -NoProfile -File sap-b1if\tests\Test-B1ifXsl.ps1

  What this cannot check is B1if itself: the message shapes here are the
  documented ones, and the first event on the server is what proves them.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:pass = 0

function Invoke-Xsl {
	param([string] $Xsl, [string] $Xml, [string] $Atom = 'atomX', [hashtable] $Params = @{})
	$t = New-Object System.Xml.Xsl.XslCompiledTransform
	$t.Load((Join-Path $root $Xsl))
	$args = New-Object System.Xml.Xsl.XsltArgumentList
	$args.AddParam('atom', '', $Atom)
	foreach ($k in $Params.Keys) { $args.AddParam($k, '', [string]$Params[$k]) }
	$r = New-Object System.Xml.XmlDocument
	$r.LoadXml($Xml)
	$sw = New-Object System.IO.StringWriter
	$t.Transform($r, $args, $sw)
	$out = New-Object System.Xml.XmlDocument
	$out.LoadXml($sw.ToString())
	return $out
}

function Check {
	param([string] $Name, [bool] $Ok, [string] $Detail = '')
	if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

function X { param($Doc, [string] $Path) return $Doc.SelectSingleNode($Path) }
function XS { param($Doc, [string] $Path) $n = $Doc.SelectSingleNode($Path); if ($n) { return $n.InnerText } return $null }

$ns = 'xmlns:vpf="urn:com.sap.b1i.vplatform:entity" xmlns:jdbc="urn:com.sap.b1i.adapter:jdbcadapter" xmlns:b1e="urn:com.sap.b1i.sim:b1event"'

function Event { param([string] $Entry, [string] $Type = '17')
	return "<vpf:Payload Role=`"T`"><b1e:b1events><b1e:b1event><b1e:ObjectType>$Type</b1e:ObjectType><b1e:TransactionType>A</b1e:TransactionType><b1e:keys><b1e:key><b1e:name>DocEntry</b1e:name><b1e:value>$Entry</b1e:value></b1e:key></b1e:keys></b1e:b1event></b1e:b1events></vpf:Payload>"
}
function Rows { param([string] $Id, [object[]] $Rows)
	$s = "<vpf:Payload Role=`"X`" id=`"$Id`"><jdbc:ResultSet>"
	foreach ($r in $Rows) {
		$s += '<jdbc:Row>'
		foreach ($k in $r.Keys) { $s += "<jdbc:$k>$([System.Security.SecurityElement]::Escape([string]$r[$k]))</jdbc:$k>" }
		$s += '</jdbc:Row>'
	}
	return $s + '</jdbc:ResultSet></vpf:Payload>'
}
function Msg { param([string[]] $Payloads) return "<vpf:Msg $ns><vpf:Header/><vpf:Body>$($Payloads -join '')</vpf:Body></vpf:Msg>" }

# ---------------------------------------------------------------- step 1 sql
$o = Invoke-Xsl 'step1-mt-po\sql.xsl' (Msg (Event '557')) 'atom0'
$st = XS $o '//Sql/Statement'
Check 'step1_sql_puts_the_event_DocEntry_in_the_where' ($st -match 'WHERE T0\.DocEntry = 557\b')
Check 'step1_sql_reads_settings_from_MANNA_IC' ($st -match '\[@MANNA_IC\]')
Check 'step1_sql_finds_an_earlier_po_by_U_MannaMtSo' ($st -match 'U_MannaMtSo')
Check 'step1_sql_keeps_earlier_payloads' ($null -ne (X $o '//*[@Role="T"]'))
$o = Invoke-Xsl 'step1-mt-po\sql.xsl' (Msg (Event "1; DROP TABLE OPOR")) 'atom0'
Check 'step1_sql_turns_a_key_that_is_not_a_number_into_a_query_for_nothing' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS DocEntry')
$o = Invoke-Xsl 'step1-mt-po\sql.xsl' (Msg (Event '12.5')) 'atom0'
Check 'step1_sql_refuses_a_fractional_key' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS DocEntry')

# -------------------------------------------------------------- step 1 final
function SoRow { param([hashtable] $Over = @{})
	$r = [ordered]@{
		DocEntry = '557'; DocNum = '557'; Cancelled = 'N'; DocStatus = 'O'; HeaderDisc = '0.000000'
		DocDate = '2026-11-04'; DueDate = '2026-11-10'; NumAtCard = 'SAL-ORD-2026-00163'; Remarks = 'From ERPNext SAL-ORD-2026-00163 - rep Arun'
		LineNum = '0'; ItemCode = 'PMB00101002'; Quantity = '120.500000'; PriceAfVAT = '253.000000'; VatPrcnt = '18.000000'; LineDisc = '0'
		InvntItem = 'Y'; PrchseItem = 'Y'; ItemFrozen = 'N'
		Enabled = 'Y'; StartDate = '2026-11-01'; Margin = '20'; Vendor = 'S-1010'; PoSeries = '199'; PoBranch = '1'; PoWhs = '01'; PoLocation = '2'
		HomeState = 'KL'; TaxInState = 'CG+SG@18'; TaxOutState = 'IGST@18'; ErpPrefix = 'SAL-ORD-'
		VendorType = 'S'; VendorFrozen = 'N'; VendorState = 'KL'; PoCount = '0'; PoDocNum = ''
	}
	foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
	return $r
}
function Step1 { param([object[]] $Rows) return Invoke-Xsl 'step1-mt-po\final.xsl' (Msg @((Event '557'), (Rows 'atom2' $Rows))) 'atom3' }

$o = Step1 @((SoRow), (SoRow @{ LineNum = '1'; ItemCode = 'PMB00101502'; Quantity = '80'; PriceAfVAT = '243' }))
Check 'a_clean_sales_order_makes_a_purchase_order' ((XS $o '//Decision/Make') -eq 'Y') (XS $o '//Decision/Reason')
Check 'the_purchase_order_is_to_the_VENDOR_setting' ((XS $o '//Documents/row/CardCode') -eq 'S-1010')
Check 'the_purchase_order_carries_the_sales_orders_DocEntry' ((XS $o '//Documents/row/U_MannaMtSo') -eq '557')
Check 'the_ERPNext_name_is_copied_so_the_sync_can_adopt_it' ((XS $o '//Documents/row/NumAtCard') -eq 'SAL-ORD-2026-00163')
Check 'the_series_and_branch_come_from_the_settings' ((XS $o '//Documents/row/Series') -eq '199' -and (XS $o '//Documents/row/BPL_IDAssignedToInvoice') -eq '1')
Check 'the_due_date_is_in_DI_format' ((XS $o '//Documents/row/DocDueDate') -eq '20261110')
Check 'every_line_is_copied' ($o.SelectNodes('//Document_Lines/row').Count -eq 2)
Check 'the_kilos_are_the_sales_orders' ((XS $o '//Document_Lines/row[1]/Quantity') -eq '120.5')
# 253 - 20 = 233 incl. GST -> 233 / 1.18 = 197.457627 net; the hand PO 233 is 232.46 gross against SO 554's 253.
Check 'the_price_is_the_rate_less_the_margin_without_gst' ((XS $o '//Document_Lines/row[1]/Price') -eq '197.457627') (XS $o '//Document_Lines/row[1]/Price')
Check 'the_second_line_is_priced_from_its_own_rate' ((XS $o '//Document_Lines/row[2]/Price') -eq '188.983051') (XS $o '//Document_Lines/row[2]/Price')
Check 'a_kerala_supplier_is_CG_SG' ((XS $o '//Document_Lines/row[1]/TaxCode') -eq 'CG+SG@18')
Check 'the_warehouse_and_location_come_from_the_settings' ((XS $o '//Document_Lines/row[1]/WarehouseCode') -eq '01' -and (XS $o '//Document_Lines/row[1]/LocationCode') -eq '2')
Check 'no_discount_can_reprice_it' ((XS $o '//Documents/row/DiscountPercent') -eq '0' -and (XS $o '//Document_Lines/row[1]/DiscountPercent') -eq '0')
Check 'the_bom_is_a_purchase_order' ((XS $o '//BOM/BO/AdmInfo/Object') -eq '22')
Check 'a_purchase_order_is_inserted_as_object_22' ((XS $o '//Decision/CallMethod') -eq 'Synchronous Insert' -and (XS $o '//Decision/CallObject') -eq '22')
Check 'nothing_names_the_end_customer' (-not ((X $o '//BOM').OuterXml -match 'CardName|C-\d'))

$o = Step1 @(SoRow @{ VendorState = 'KA' })
Check 'a_supplier_in_another_state_is_IGST' ((XS $o '//Document_Lines/row[1]/TaxCode') -eq 'IGST@18')
$o = Step1 @(SoRow @{ VendorState = 'kl' })
Check 'the_state_is_compared_without_case' ((XS $o '//Document_Lines/row[1]/TaxCode') -eq 'CG+SG@18')
$o = Step1 @(SoRow @{ HeaderDisc = '10' })
# 253 * 0.9 = 227.70 - 20 = 207.70 / 1.18 = 176.016949
Check 'a_header_discount_lowers_what_manna_pays' ((XS $o '//Document_Lines/row[1]/Price') -eq '176.016949') (XS $o '//Document_Lines/row[1]/Price')

function Refused { param($Doc, [string] $Like) return ((XS $Doc '//Decision/Make') -eq 'N' -and (XS $Doc '//Decision/Reason') -like $Like -and $null -eq (X $Doc '//BOM')) }
Check 'no_rows_makes_nothing' (Refused (Step1 @()) 'skip: the sales order was not found')
function OnlyReads { param($Doc) return ((XS $Doc '//Decision/CallMethod') -eq 'Synchronous Retrieval' -and (XS $Doc '//Decision/CallObject') -eq '17' -and (XS $Doc '//Decision/CallKey') -eq '557') }
Check 'a_refusal_only_reads_the_sales_order_back' (OnlyReads (Step1 @(SoRow @{ Enabled = 'N' })))
Check 'a_sales_order_the_query_missed_is_still_named_from_the_event' (OnlyReads (Step1 @()))
Check 'a_hand_keyed_order_only_reads_the_sales_order_back' (OnlyReads (Step1 @(SoRow @{ NumAtCard = 'CUST PO 4471'; Remarks = 'urgent' })))
Check 'switched_off_makes_nothing' (Refused (Step1 @(SoRow @{ Enabled = 'N' })) 'skip:*ENABLED*')
Check 'an_order_before_START_DATE_is_left_alone' (Refused (Step1 @(SoRow @{ DocDate = '2026-10-31' })) 'skip:*START_DATE*')
Check 'no_START_DATE_is_refused_not_assumed' (Refused (Step1 @(SoRow @{ StartDate = '' })) 'START_DATE is not set*')
Check 'an_order_keyed_in_SAP_makes_nothing' (Refused (Step1 @(SoRow @{ NumAtCard = 'CUST PO 4471'; Remarks = 'urgent' })) 'skip: not an order from ERPNext*')
Check 'an_order_keyed_in_SAP_with_no_reference_makes_nothing' (Refused (Step1 @(SoRow @{ NumAtCard = ''; Remarks = '' })) 'skip: not an order from ERPNext*')
Check 'an_ERPNext_looking_reference_typed_in_SAP_is_not_enough' (Refused (Step1 @(SoRow @{ Remarks = 'copied from SAL-ORD-2026-00163' })) 'skip: not an order from ERPNext*')
Check 'remarks_naming_another_ERPNext_order_are_not_enough' (Refused (Step1 @(SoRow @{ Remarks = 'From ERPNext SAL-ORD-2026-00999' })) 'skip: not an order from ERPNext*')
Check 'a_prefix_without_remarks_is_not_enough' (Refused (Step1 @(SoRow @{ Remarks = '' })) 'skip: not an order from ERPNext*')
Check 'no_ERP_PREFIX_setting_is_refused_not_assumed' (Refused (Step1 @(SoRow @{ ErpPrefix = '' })) 'ERP_PREFIX is not set*')
Check 'a_cancelled_order_makes_nothing' (Refused (Step1 @(SoRow @{ Cancelled = 'Y' })) 'skip:*cancelled*')
Check 'a_second_event_for_the_same_order_makes_nothing' (Refused (Step1 @(SoRow @{ PoCount = '1'; PoDocNum = '239' })) 'skip: purchase order 239 already*')
Check 'no_margin_is_refused' (Refused (Step1 @(SoRow @{ Margin = '' })) 'no MARGIN*')
Check 'a_zero_margin_is_refused' (Refused (Step1 @(SoRow @{ Margin = '0' })) 'no MARGIN*')
Check 'a_missing_supplier_is_refused' (Refused (Step1 @(SoRow @{ VendorType = '' })) 'supplier S-1010*')
Check 'an_inactive_supplier_is_refused' (Refused (Step1 @(SoRow @{ VendorFrozen = 'Y' })) '*inactive*')
Check 'a_supplier_with_no_state_is_refused_not_guessed' (Refused (Step1 @(SoRow @{ VendorState = '' })) 'no tax code*')
Check 'a_line_with_no_item_is_refused' (Refused (Step1 @((SoRow), (SoRow @{ ItemCode = '' }))) 'a line has no item')
Check 'a_non_stock_item_is_refused' (Refused (Step1 @((SoRow), (SoRow @{ ItemCode = 'FREIGHT'; InvntItem = 'N' }))) 'FREIGHT is not*')
Check 'an_item_manna_cannot_buy_is_refused' (Refused (Step1 @(SoRow @{ PrchseItem = 'N' })) 'PMB00101002 is not*')
Check 'a_frozen_item_is_refused' (Refused (Step1 @(SoRow @{ ItemFrozen = 'Y' })) 'PMB00101002 is not*')
Check 'a_line_with_no_kilos_is_refused' (Refused (Step1 @(SoRow @{ Quantity = '0' })) 'a line has no quantity')
Check 'a_rate_not_above_the_margin_is_refused' (Refused (Step1 @(SoRow @{ PriceAfVAT = '20' })) '*no more than the margin*')

# ---------------------------------------------------------------- step 1 bom (atom6, before B1 Object)
function Bom1 { param($Decision) return Invoke-Xsl 'step1-mt-po\bom.xsl' $Decision.OuterXml 'atom6' }
$o = Bom1 (Step1 @(SoRow))
Check 'step1_bom_hands_the_B1_Object_atom_only_the_purchase_order' ((XS $o '//*[@id="atom6"]/Documents/row/CardCode') -eq 'S-1010' -and $o.SelectNodes('//*[@id="atom6"]/Document_Lines/row').Count -eq 1)
Check 'step1_bom_payload_holds_the_documents_and_lines_and_nothing_else' (($o.SelectSingleNode('//*[@id="atom6"]')).ChildNodes.Count -eq 2)
Check 'step1_bom_leaves_the_BOM_wrapper_to_the_B1_Object_atom' ($null -eq (X $o '//*[@id="atom6"]//AdmInfo') -and $null -eq (X $o '//*[@id="atom6"]//BOM'))
$o = Bom1 (Step1 @(SoRow @{ Enabled = 'N' }))
Check 'step1_bom_of_a_refusal_is_empty_so_nothing_is_written' (($o.SelectSingleNode('//*[@id="atom6"]')).ChildNodes.Count -eq 0)

# ---------------------------------------------------------------- step 2 sql
$o = Invoke-Xsl 'step2-ht-so\sql-mt.xsl' (Msg (Event '239' '22')) 'atom0'
Check 'step2_sql_mt_reads_the_purchase_order_of_the_event' ((XS $o '//Sql/Statement') -match 'WHERE P\.DocEntry = 239\b')
Check 'step2_sql_mt_reads_the_sales_orders_number' ((XS $o '//Sql/Statement') -match 'SO\.DocNum AS nvarchar\(20\)\), ''''\) AS MtSoNum')
# In step 1's flow the event is the sales order's, and the purchase order is the one B1if just made for it.
$o = Invoke-Xsl 'step2-ht-so\sql-mt.xsl' (Msg (Event '6914')) 'atom7' @{ keyOf = 'so' }
$st = XS $o '//Sql/Statement'
Check 'step2_sql_mt_in_step1_finds_the_purchase_order_made_for_the_sales_order' ($st -match "U_MannaMtSo = N'6914' AND Q\.CANCELED = 'N'") $st
Check 'step2_sql_mt_in_step1_does_not_read_a_purchase_order_by_the_sales_orders_number' ($st -notmatch 'WHERE P\.DocEntry = 6914')
$o = Invoke-Xsl 'step2-ht-so\sql-mt.xsl' (Msg (Event "1' OR 1=1 --")) 'atom7' @{ keyOf = 'so' }
Check 'step2_sql_mt_in_step1_turns_a_key_that_is_not_a_number_into_a_query_for_nothing' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS DocEntry')
$o = Invoke-Xsl 'step2-ht-so\sql-mt.xsl' (Msg (Event '239' '22')) 'atom0'
Check 'step2_sql_mt_on_its_own_still_reads_by_the_purchase_orders_DocEntry' ((XS $o '//Sql/Statement') -notmatch 'U_MannaMtSo = N')
Check 'step2_sql_mt_on_its_own_reads_with_locks' ((XS $o '//Sql/Statement') -notmatch 'NOLOCK')
$o = Invoke-Xsl 'step2-ht-so\sql-mt.xsl' (Msg (Event '6914')) 'atom7' @{ keyOf = 'so' }
$st = XS $o '//Sql/Statement'
Check 'step2_sql_mt_in_step1_does_not_wait_for_the_purchase_order_its_own_run_has_not_committed' (([regex]::Matches($st, 'WITH \(NOLOCK\)')).Count -eq 6) $st

function PoRow { param([hashtable] $Over = @{})
	$r = [ordered]@{
		DocEntry = '239'; DocNum = '239'; Cancelled = 'N'; CardCode = 'S-1010'; HeaderDisc = '0'
		NumAtCard = 'SAL-ORD-2026-00163'; MtSo = '557'; DueDate = '2026-11-10'
		LineNum = '0'; ItemCode = 'PMB00101002'; Quantity = '120.5'; Price = '197.457627'; SlpName = "Arun D'Souza"; MtSoNum = '557'; Vendor = 'S-1010'
	}
	foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
	return $r
}
$o = Invoke-Xsl 'step2-ht-so\sql-ht.xsl' (Msg @((Event '239' '22'), (Rows 'atom2' @((PoRow), (PoRow @{ LineNum = '1'; ItemCode = "PMB'X" }))))) 'atom3'
$st = XS $o '//Sql/Statement'
Check 'step2_sql_ht_lists_every_item_of_the_purchase_order' ($st -match "\(N'PMB00101002'\), \(N'PMB''X'\)") $st
Check 'step2_sql_ht_quotes_the_reps_name' ($st -match "SlpName = N'Arun D''Souza'")
Check 'step2_sql_ht_finds_an_earlier_order_by_U_MannaMtPo' ($st -match "U_MannaMtPo = N'239'")
$o = Invoke-Xsl 'step2-ht-so\sql-ht.xsl' (Msg @((Event '239' '22'), (Rows 'atom2' @()))) 'atom3'
Check 'step2_sql_ht_asks_nothing_when_there_is_no_purchase_order' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS ItemCode')

# -------------------------------------------------------------- step 2 final
function HtRow { param([hashtable] $Over = @{})
	$r = [ordered]@{
		ItemCode = 'PMB00101002'; SellItem = 'Y'; InvntItem = 'Y'; ItemFrozen = 'N'
		Enabled = 'Y'; Customer = '10118'; SoSeries = '179'; SoWhs = '07'; HomeState = 'KL'; TaxInState = 'CG+SG@18'; TaxOutState = 'IGST@18'
		CustomerType = 'C'; CustomerFrozen = 'N'; CustomerState = 'KL'; SoCount = '0'; SoDocNum = ''; SlpCode = '7'
	}
	foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
	return $r
}
function Step2 { param([object[]] $Po, [object[]] $Ht) return Invoke-Xsl 'step2-ht-so\final.xsl' (Msg @((Event '239' '22'), (Rows 'atom2' $Po), (Rows 'atom4' $Ht))) 'atom5' }

$o = Step2 @((PoRow), (PoRow @{ LineNum = '1'; ItemCode = 'PMB00101502'; Quantity = '80'; Price = '188.983051' })) @((HtRow), (HtRow @{ ItemCode = 'PMB00101502' }))
Check 'a_b1if_purchase_order_makes_a_hitech_order' ((XS $o '//Decision/Make') -eq 'Y') (XS $o '//Decision/Reason')
Check 'the_hitech_order_is_to_CUSTOMER' ((XS $o '//Documents/row/CardCode') -eq '10118')
Check 'the_hitech_order_carries_the_purchase_orders_DocEntry' ((XS $o '//Documents/row/U_MannaMtPo') -eq '239')
Check 'the_hitech_order_carries_the_manna_sales_order_number_to_search_by' ((XS $o '//Documents/row/U_MannaMtSoNo') -eq '557')
Check 'the_hitech_order_keeps_the_ERPNext_name_for_PASS_B' ((XS $o '//Documents/row/NumAtCard') -eq 'SAL-ORD-2026-00163')
Check 'the_hitech_order_is_priced_as_the_purchase_order' ((XS $o '//Document_Lines/row[1]/Price') -eq '197.457627' -and (XS $o '//Document_Lines/row[2]/Price') -eq '188.983051')
Check 'the_hitech_order_has_the_purchase_orders_kilos' ((XS $o '//Document_Lines/row[2]/Quantity') -eq '80')
Check 'the_hitech_order_is_in_the_SO_WHS_warehouse' ((XS $o '//Document_Lines/row[1]/WarehouseCode') -eq '07')
Check 'the_hitech_order_carries_the_rep' ((XS $o '//Documents/row/SalesPersonCode') -eq '7')
Check 'the_hitech_order_names_only_the_purchase_order' ((XS $o '//Documents/row/Comments') -eq 'Manna Treads PO 239 - made by B1if')
Check 'the_hitech_bom_is_a_sales_order' ((XS $o '//BOM/BO/AdmInfo/Object') -eq '17')
Check 'a_hitech_order_is_inserted_as_object_17' ((XS $o '//Decision/CallMethod') -eq 'Synchronous Insert' -and (XS $o '//Decision/CallObject') -eq '17')
$b = Invoke-Xsl 'step2-ht-so\bom.xsl' $o.OuterXml 'atom6'
Check 'step2_bom_hands_the_B1_Object_atom_only_the_hitech_order' ((XS $b '//*[@id="atom6"]/Documents/row/CardCode') -eq '10118' -and ($b.SelectSingleNode('//*[@id="atom6"]')).ChildNodes.Count -eq 2 -and $null -eq (X $b '//*[@id="atom6"]//AdmInfo'))
$o = Step2 @(PoRow @{ NumAtCard = '' }) @(HtRow)
Check 'with_no_ERPNext_name_the_reference_is_the_purchase_order' ((XS $o '//Documents/row/NumAtCard') -eq 'MT PO 239')
$o = Step2 @(PoRow) @(HtRow @{ SlpCode = '' })
Check 'an_unknown_rep_is_left_to_SAPs_default' ($null -eq (X $o '//Documents/row/SalesPersonCode'))
$o = Step2 @(PoRow) @(HtRow @{ CustomerState = 'TN' })
Check 'a_customer_in_another_state_is_IGST_at_hitech' ((XS $o '//Document_Lines/row[1]/TaxCode') -eq 'IGST@18')

Check 'no_purchase_order_makes_nothing' (Refused (Step2 @() @()) 'skip: the purchase order was not found')
Check 'a_hand_keyed_purchase_order_is_not_followed' (Refused (Step2 @(PoRow @{ MtSo = '' }) @(HtRow)) 'skip: not made by B1if*')
Check 'a_cancelled_purchase_order_makes_nothing' (Refused (Step2 @(PoRow @{ Cancelled = 'Y' }) @(HtRow)) 'skip:*cancelled*')
Check 'a_purchase_order_to_someone_else_makes_nothing' (Refused (Step2 @(PoRow @{ CardCode = 'S-2000' }) @(HtRow)) 'skip:*not to Hi-Tech*')
Check 'hitech_switched_off_makes_nothing' (Refused (Step2 @(PoRow) @(HtRow @{ Enabled = '' })) 'skip:*ENABLED*')
Check 'a_second_event_for_the_same_purchase_order_makes_nothing' (Refused (Step2 @(PoRow) @(HtRow @{ SoCount = '1'; SoDocNum = '560' })) 'skip: Hi-Tech order 560 already*')
Check 'a_header_discount_on_the_purchase_order_is_refused' (Refused (Step2 @(PoRow @{ HeaderDisc = '5' }) @(HtRow)) '*header discount*')
Check 'a_missing_customer_is_refused' (Refused (Step2 @(PoRow) @(HtRow @{ CustomerType = 'S' })) 'customer 10118*')
Check 'an_inactive_customer_is_refused' (Refused (Step2 @(PoRow) @(HtRow @{ CustomerFrozen = 'Y' })) '*inactive*')
Check 'a_customer_with_no_state_is_refused' (Refused (Step2 @(PoRow) @(HtRow @{ CustomerState = '' })) 'no tax code*')
Check 'an_item_hitech_does_not_have_is_refused' (Refused (Step2 @(PoRow) @(HtRow @{ SellItem = ''; InvntItem = '' })) 'PMB00101002 is not*')
Check 'an_item_hitech_cannot_sell_is_refused' (Refused (Step2 @(PoRow) @(HtRow @{ SellItem = 'N' })) 'PMB00101002 is not*')
Check 'a_purchase_order_line_with_no_price_is_refused' (Refused (Step2 @(PoRow @{ Price = '0' }) @(HtRow)) '*no quantity or price')
function OnlyReadsCustomer { param($Doc) return ((XS $Doc '//Decision/CallMethod') -eq 'Synchronous Retrieval' -and (XS $Doc '//Decision/CallObject') -eq '2' -and (XS $Doc '//Decision/CallKeyName') -eq 'CardCode' -and (XS $Doc '//Decision/CallKey') -eq '10118') }
Check 'a_step2_refusal_only_reads_the_hitech_customer_back' (OnlyReadsCustomer (Step2 @(PoRow @{ HeaderDisc = '5' }) @(HtRow)))
Check 'a_hand_keyed_purchase_order_only_reads_the_hitech_customer_back' (OnlyReadsCustomer (Step2 @(PoRow @{ MtSo = '' }) @(HtRow)))
$o = Step2 @(PoRow @{ MtSo = '' }) @(HtRow)
$b = Invoke-Xsl 'step2-ht-so\bom.xsl' $o.OuterXml 'atom6'
Check 'step2_bom_of_a_refusal_is_empty_so_nothing_is_written' (($b.SelectSingleNode('//*[@id="atom6"]')).ChildNodes.Count -eq 0)

# ---------------------------------------------------------------- step 3 (stage 4: the pick list)
$o = Invoke-Xsl 'step3-pick\sql-ht.xsl' (Msg @()) 'atom1'
$st = XS $o '//Sql/Statement'
Check 'step3_sql_ht_needs_no_event_it_runs_on_a_timer' ($st -match 'FROM OPKL K' -and $st -notmatch 'AbsEntry = \d') $st
Check 'step3_sql_ht_takes_only_lists_whose_remarks_carry_an_erpnext_name' ($st -match "LIKE 'ERPNext % - %'" -and $st -match "X\.PickName <> ''")
Check 'step3_sql_ht_skips_a_list_an_invoice_already_carries' ($st -match "NOT EXISTS \(SELECT 1 FROM OINV V WHERE V\.NumAtCard = X\.PickName AND V\.CANCELED = 'N'\)")
Check 'step3_sql_ht_skips_a_closed_list' ($st -match "K\.Status <> 'C'")
Check 'step3_sql_ht_takes_waiting_lists_in_turn_so_a_refused_one_cannot_block_the_rest' ($st -match "W\.Rn = DATEDIFF\(MINUTE, '20260101', GETDATE\(\)\) % W\.N \+ 1")
Check 'step3_sql_ht_always_returns_the_settings_row' ($st -match "FROM \(\s*SELECT\s+MAX\(CASE WHEN Code = 'ENABLED'" -and $st -match 'LEFT JOIN \(\s*SELECT W\.AbsEntry')
Check 'step3_sql_ht_starts_with_select_for_the_call_sql_atom' ($st.TrimStart().StartsWith('SELECT'))

function PkRow { param([hashtable] $Over = @{})
	$r = [ordered]@{
		PickEntry = '7'; PickName = 'PICK-00012'; Waiting = '1'; PickLine = '0'; BaseObject = '17'; OrderEntry = '3040'; OrderLine = '1'; Kg = '31.400000'
		SoNum = '555'; SoCancelled = 'N'; SoCard = '10118'; MtPo = '2023'; OrderName = 'SAL-ORD-2026-00167'
		ItemCode = 'PMB00101502'; SoLineStatus = 'O'; WhsCode = '07'; Batch = 'Y'
		Enabled = 'Y'; Customer = '10118'; InvSeries = ''; Today = '2026-11-05'
	}
	foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
	return $r
}
function BtRow { param([string] $Batch, [string] $Avail, [string] $Item = 'PMB00101502', [string] $Whs = '07')
	return [ordered]@{ ItemCode = $Item; WhsCode = $Whs; BatchNum = $Batch; Avail = $Avail }
}
function MtRow { param([hashtable] $Over = @{})
	$r = [ordered]@{
		Kind = 'PO'; DocEntry = '2023'; DocNum = '241'; CardCode = 'S-1010'; Cancelled = 'N'; MtSo = '6915'; LineNum = '1'; ItemCode = 'PMB00101502'; LineStatus = 'O'
		Enabled = 'Y'; Vendor = 'S-1010'; Branch = '1'; GrpoSeries = ''; DnSeries = '211'; GrpoCount = '0'; DnCount = '0'
	}
	foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
	return $r
}
function MtRows { param([hashtable] $Over = @{})
	return @(
		(MtRow (@{ Kind = 'PO'; LineNum = '0'; ItemCode = 'PMB00101002' } + $Over)),
		(MtRow (@{ Kind = 'PO'; LineNum = '1' } + $Over)),
		(MtRow (@{ Kind = 'SO'; DocEntry = '6915'; DocNum = '576'; CardCode = 'C-1687'; MtSo = ''; LineNum = '0'; ItemCode = 'PMB00101002' } + $Over)),
		(MtRow (@{ Kind = 'SO'; DocEntry = '6915'; DocNum = '576'; CardCode = 'C-1687'; MtSo = ''; LineNum = '1' } + $Over))
	)
}

$o = Invoke-Xsl 'step3-pick\sql-batch.xsl' (Msg @((Event '7' '156'), (Rows 'atom2' @((PkRow), (PkRow @{ ItemCode = "PMB'X"; WhsCode = '01' }))))) 'atom3'
$st = XS $o '//Sql/Statement'
Check 'step3_sql_batch_reads_each_batch_item_in_its_own_warehouse' ($st -match "Q\.ItemCode = N'PMB00101502' AND Q\.WhsCode = N'07'" -and $st -match "Q\.ItemCode = N'PMB''X' AND Q\.WhsCode = N'01'") $st
Check 'step3_sql_batch_reads_oldest_first' ($st -match 'ORDER BY Q\.ItemCode, Q\.WhsCode, N\.InDate, N\.AbsEntry')
$o = Invoke-Xsl 'step3-pick\sql-batch.xsl' (Msg @((Event '7' '156'), (Rows 'atom2' @((PkRow @{ Batch = 'N' }))))) 'atom3'
Check 'step3_sql_batch_asks_nothing_when_no_item_is_batch_managed' ((XS $o '//Sql/Statement').Trim() -eq "SELECT TOP 0 '' AS ItemCode")

$o = Invoke-Xsl 'step3-pick\sql-mt.xsl' (Msg @((Event '7' '156'), (Rows 'atom2' @((PkRow @{ PickName = "PICK-0'1" }))))) 'atom5'
$st = XS $o '//Sql/Statement'
Check 'step3_sql_mt_reads_the_purchase_order_hitechs_order_was_made_for' ($st -match 'WHERE P\.DocEntry = 2023\b') $st
Check 'step3_sql_mt_reads_the_sales_order_that_purchase_order_was_made_for' ($st -match 'FROM OPOR WHERE DocEntry = 2023\)')
Check 'step3_sql_mt_quotes_the_list_name' ($st -match "NumAtCard = N'PICK-0''1'")
$o = Invoke-Xsl 'step3-pick\sql-mt.xsl' (Msg @((Event '7' '156'), (Rows 'atom2' @((PkRow @{ MtPo = '' }))))) 'atom5'
$st = XS $o '//Sql/Statement'
Check 'step3_sql_mt_without_a_purchase_order_still_reads_the_settings_the_vendor_read_needs' ($st -match "SELECT '' AS Kind, S\.\*" -and $st -match "Code = 'VENDOR'" -and $st -notmatch 'OPOR') $st

function Step3 { param([object[]] $Pk, [object[]] $Bt, [object[]] $Mt)
	return Invoke-Xsl 'step3-pick\final.xsl' (Msg @((Event '7' '156'), (Rows 'atom2' $Pk), (Rows 'atom4' $Bt), (Rows 'atom6' $Mt))) 'atom7'
}
$two = @((PkRow @{ PickLine = '0'; OrderLine = '0'; ItemCode = 'PMB00101002'; Batch = 'N'; Kg = '48.6' }), (PkRow))
$bts = @((BtRow 'OLD-01' '20'), (BtRow 'NEW-02' '100'))
$o = Step3 $two $bts (MtRows)
Check 'step3_makes_all_three_for_a_list_from_erpnext' ((XS $o '//Decision/Make') -eq 'Y') (XS $o '//Decision/Reason')
Check 'step3_inserts_hitechs_invoice_on_hitech' ((XS $o '//Decision/Inv/CallMethod') -eq 'Synchronous Insert' -and (XS $o '//Decision/Inv/CallObject') -eq '13')
Check 'step3_inserts_the_goods_receipt_and_delivery' ((XS $o '//Decision/Grpo/CallObject') -eq '20' -and (XS $o '//Decision/Dn/CallObject') -eq '15')
Check 'step3_invoice_is_to_manna_treads_and_carries_the_list_name' ((XS $o '//Inv//Documents/row/CardCode') -eq '10118' -and (XS $o '//Inv//Documents/row/NumAtCard') -eq 'PICK-00012')
Check 'step3_invoice_is_due_today_so_payment_terms_cannot_put_it_outside_the_periods' ((XS $o '//Inv//Documents/row/DocDueDate') -eq '20261105')
$il = $o.SelectNodes('//Inv//Document_Lines/row')
Check 'step3_invoice_lines_are_based_on_hitechs_order_lines_for_the_picked_kilos' ($il.Count -eq 2 -and $il[0].BaseType -eq '17' -and $il[0].BaseEntry -eq '3040' -and $il[0].BaseLine -eq '0' -and $il[0].Quantity -eq '48.6' -and $il[1].BaseLine -eq '1' -and $il[1].Quantity -eq '31.4')
$bn = $o.SelectNodes('//Inv//BatchNumbers/row')
Check 'step3_batches_are_taken_oldest_first_until_the_kilos_are_covered' ($bn.Count -eq 2 -and $bn[0].BatchNumber -eq 'OLD-01' -and $bn[0].Quantity -eq '20' -and $bn[1].BatchNumber -eq 'NEW-02' -and $bn[1].Quantity -eq '11.4') (($bn | ForEach-Object { "$($_.BatchNumber)=$($_.Quantity)" }) -join ',')
Check 'step3_batches_go_on_the_invoice_line_of_their_item' ($bn[0].BaseLineNumber -eq '1' -and $bn[1].BaseLineNumber -eq '1')
$o1 = Step3 @((PkRow)) @((BtRow 'OLD-01' '50'), (BtRow 'NEW-02' '100')) (MtRows)
Check 'step3_one_batch_that_holds_enough_is_the_only_one_used' ($o1.SelectNodes('//Inv//BatchNumbers/row').Count -eq 1 -and (XS $o1 '//Inv//BatchNumbers/row/Quantity') -eq '31.4')
Check 'step3_no_batch_item_no_batch_table' ($null -eq (X (Step3 @((PkRow @{ Batch = 'N' })) @() (MtRows)) '//Inv//BatchNumbers'))
$gl = $o.SelectNodes('//Grpo//Document_Lines/row')
Check 'step3_goods_receipt_lines_are_based_on_the_purchase_order_line_for_the_same_item' ($gl.Count -eq 2 -and $gl[0].BaseType -eq '22' -and $gl[0].BaseEntry -eq '2023' -and $gl[0].BaseLine -eq '0' -and $gl[1].BaseLine -eq '1' -and $gl[1].Quantity -eq '31.4')
Check 'step3_goods_receipt_is_from_hitech_on_the_branch' ((XS $o '//Grpo//Documents/row/CardCode') -eq 'S-1010' -and (XS $o '//Grpo//Documents/row/BPL_IDAssignedToInvoice') -eq '1' -and (XS $o '//Grpo//Documents/row/NumAtCard') -eq 'PICK-00012')
$dl = $o.SelectNodes('//Dn//Document_Lines/row')
Check 'step3_delivery_lines_are_based_on_manna_treads_sales_order_lines' ($dl.Count -eq 2 -and $dl[0].BaseType -eq '17' -and $dl[0].BaseEntry -eq '6915' -and $dl[1].BaseLine -eq '1' -and $dl[1].Quantity -eq '31.4')
Check 'step3_delivery_is_to_the_customer_in_its_own_series' ((XS $o '//Dn//Documents/row/CardCode') -eq 'C-1687' -and (XS $o '//Dn//Documents/row/Series') -eq '211' -and (XS $o '//Dn//Documents/row/BPL_IDAssignedToInvoice') -eq '1')
$o1 = Step3 @((PkRow @{ ItemCode = 'PMB00101002'; OrderLine = '0'; Batch = 'N' })) @() (MtRows)
Check 'step3_a_product_left_off_the_list_is_on_none_of_the_three' ($o1.SelectNodes('//Inv//Document_Lines/row').Count -eq 1 -and $o1.SelectNodes('//Grpo//Document_Lines/row').Count -eq 1 -and $o1.SelectNodes('//Dn//Document_Lines/row').Count -eq 1 -and (XS $o1 '//Dn//Document_Lines/row/BaseLine') -eq '0')

function Refused3 { param($Doc, [string] $Like) $r = XS $Doc '//Decision/Reason'; return ((XS $Doc '//Decision/Make') -eq 'N' -and $r -like $Like) }
Check 'step3_a_pick_list_keyed_in_sap_is_left_alone' (Refused3 (Step3 @((PkRow @{ PickName = '' })) $bts (MtRows)) 'skip: not from ERPNext*')
$idle = Step3 @((PkRow @{ PickEntry = ''; PickName = ''; Waiting = '0'; PickLine = ''; OrderEntry = ''; ItemCode = ''; MtPo = ''; Batch = 'N' })) @() @((MtRow @{ Kind = ''; DocEntry = ''; LineNum = ''; ItemCode = '' }))
Check 'step3_a_run_with_no_list_waiting_makes_nothing' (Refused3 $idle 'skip: no ERPNext pick list waiting*') (XS $idle '//Decision/Reason')
Check 'step3_a_run_with_no_list_waiting_still_has_keys_to_read_by' ((XS $idle '//Inv/CallKey') -eq '10118' -and (XS $idle '//Grpo/CallKey') -eq 'S-1010' -and (XS $idle '//Dn/CallKey') -eq 'S-1010')
Check 'step3_a_goods_receipt_already_made_makes_nothing' (Refused3 (Step3 @((PkRow)) $bts (MtRows @{ GrpoCount = '1' })) 'skip: Manna Treads already has*')
Check 'step3_hitech_switched_off_makes_nothing' (Refused3 (Step3 @((PkRow @{ Enabled = 'N' })) $bts (MtRows)) "skip: Hi-Tech's @MANNA_IC ENABLED*")
Check 'step3_manna_treads_switched_off_makes_nothing' (Refused3 (Step3 @((PkRow)) $bts (MtRows @{ Enabled = 'N' })) "skip: Manna Treads' @MANNA_IC ENABLED*")
Check 'step3_too_little_in_batches_refuses_all_three' (Refused3 (Step3 @((PkRow)) @((BtRow 'OLD-01' '20')) (MtRows)) 'not enough in batches: PMB00101502 (20 kg*')
Check 'step3_a_batch_in_another_warehouse_does_not_count' (Refused3 (Step3 @((PkRow)) @((BtRow 'OLD-01' '100' 'PMB00101502' '01')) (MtRows)) 'not enough in batches*')
Check 'step3_an_item_closed_on_the_purchase_order_refuses_all_three' (Refused3 (Step3 @((PkRow)) $bts (MtRows @{ LineStatus = 'C' })) 'not open on Manna Treads purchase order 241: PMB00101502*')
Check 'step3_an_item_closed_on_hitechs_order_refuses_all_three' (Refused3 (Step3 @((PkRow @{ SoLineStatus = 'C' })) $bts (MtRows)) 'PMB00101502 is closed on Hi-Tech sales order 555')
Check 'step3_no_delivery_series_refuses_all_three' (Refused3 (Step3 @((PkRow)) $bts (MtRows @{ DnSeries = '' })) "*has no DN_SERIES*")
Check 'step3_a_hitech_order_not_made_by_b1if_is_left_alone' (Refused3 (Step3 @((PkRow @{ MtPo = '' })) $bts @()) 'skip: Hi-Tech*not made by B1if*')
Check 'step3_a_list_over_two_orders_is_refused' (Refused3 (Step3 @((PkRow), (PkRow @{ OrderEntry = '3041' })) $bts (MtRows)) '*more than one sales order')
$n = Step3 @((PkRow @{ PickName = '' })) $bts (MtRows)
Check 'step3_a_refusal_only_reads_business_partners' ((XS $n '//Inv/CallMethod') -eq 'Synchronous Retrieval' -and (XS $n '//Inv/CallKey') -eq '10118' -and (XS $n '//Grpo/CallObject') -eq '2' -and (XS $n '//Grpo/CallKey') -eq 'S-1010' -and (XS $n '//Dn/CallKey') -eq 'S-1010')
Check 'step3_a_refusal_carries_no_documents' ($null -eq (X $n '//BOM'))

foreach ($part in 'Inv', 'Grpo', 'Dn') {
	$b = Invoke-Xsl 'step3-pick\bom.xsl' $o.OuterXml 'atom8' @{ part = $part }
	$p = $b.SelectSingleNode('//*[@id="atom8"]')
	$want = @{ Inv = '10118'; Grpo = 'S-1010'; Dn = 'C-1687' }[$part]
	Check "step3_bom_$($part)_hands_its_atom_only_its_own_document" ((XS $b '//*[@id="atom8"]/Documents/row/CardCode') -eq $want -and $null -eq (X $b '//*[@id="atom8"]//AdmInfo') -and $null -eq (X $b '//*[@id="atom8"]/BOM'))
}
$b = Invoke-Xsl 'step3-pick\bom.xsl' $o.OuterXml 'atom8' @{ part = 'Inv' }
Check 'step3_bom_of_the_invoice_carries_its_batches' ($b.SelectNodes('//*[@id="atom8"]/BatchNumbers/row').Count -eq 2)
$b = Invoke-Xsl 'step3-pick\bom.xsl' $n.OuterXml 'atom8' @{ part = 'Grpo' }
Check 'step3_bom_of_a_refusal_is_empty_so_nothing_is_written' (($b.SelectSingleNode('//*[@id="atom8"]')).ChildNodes.Count -eq 0)


Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
