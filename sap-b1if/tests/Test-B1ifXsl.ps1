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
	param([string] $Xsl, [string] $Xml, [string] $Atom = 'atomX')
	$t = New-Object System.Xml.Xsl.XslCompiledTransform
	$t.Load((Join-Path $root $Xsl))
	$args = New-Object System.Xml.Xsl.XsltArgumentList
	$args.AddParam('atom', '', $Atom)
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

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
