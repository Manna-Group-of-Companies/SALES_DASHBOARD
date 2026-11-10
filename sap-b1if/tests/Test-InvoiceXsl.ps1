<#
.SYNOPSIS
  Offline checks of step 5 (A/R invoices and incoming payments -> ERPNext).

      powershell -NoProfile -File sap-b1if\tests\Test-InvoiceXsl.ps1

  Same harness as Test-B1ifXsl.ps1: .NET's XSLT 1.0 engine against a
  hand-made B1if message. No SAP, no B1if, no ERPNext.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:pass = 0

function Invoke-Xsl {
	param([string] $Xsl, [string] $Xml, [string] $Atom = 'atomX')
	$t = New-Object System.Xml.Xsl.XslCompiledTransform
	$t.Load((Join-Path $root $Xsl))
	$a = New-Object System.Xml.Xsl.XsltArgumentList
	$a.AddParam('atom', '', $Atom)
	$r = New-Object System.Xml.XmlDocument
	$r.LoadXml($Xml)
	$sw = New-Object System.IO.StringWriter
	$t.Transform($r, $a, $sw)
	$o = New-Object System.Xml.XmlDocument
	$o.LoadXml($sw.ToString())
	return $o
}
function Check { param([string] $Name, [bool] $Ok, [string] $Detail = '')
	if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red } }
function XS { param($Doc, [string] $Path) $n = $Doc.SelectSingleNode($Path); if ($n) { return $n.InnerText } return $null }

$ns = 'xmlns:vpf="urn:com.sap.b1i.vplatform:entity" xmlns:jdbc="urn:com.sap.b1i.adapter:jdbcadapter" xmlns:b1e="urn:com.sap.b1i.sim:b1event"'
function Event { param([string] $Entry, [string] $Type)
	return "<vpf:Payload Role=`"T`"><b1e:b1events><b1e:b1event><b1e:ObjectType>$Type</b1e:ObjectType><b1e:TransactionType>A</b1e:TransactionType><b1e:keys><b1e:key><b1e:name>DocEntry</b1e:name><b1e:value>$Entry</b1e:value></b1e:key></b1e:keys></b1e:b1event></b1e:b1events></vpf:Payload>" }
function Rows { param([string] $Id, [object[]] $Rows)
	$s = "<vpf:Payload Role=`"X`" id=`"$Id`"><jdbc:ResultSet>"
	foreach ($r in $Rows) { $s += '<jdbc:Row>'; foreach ($k in $r.Keys) { $s += "<jdbc:$k>$([System.Security.SecurityElement]::Escape([string]$r[$k]))</jdbc:$k>" }; $s += '</jdbc:Row>' }
	return $s + '</jdbc:ResultSet></vpf:Payload>' }
function Msg { param([string[]] $P) return "<vpf:Msg $ns><vpf:Header/><vpf:Body>$($P -join '')</vpf:Body></vpf:Msg>" }

# ---------------------------------------------------------------- sql
$o = Invoke-Xsl 'step5-invoice\sql.xsl' (Msg (Event '9559' '13')) 'atom0'
$st = XS $o '//Sql/Statement'
Check 'an invoice event reads that invoice' ($st -match 'I\.DocEntry = 9559\b')
Check 'it reads the settings from MANNA_IC' ($st -match 'ERP_INVOICE_SYNC' -and $st -match 'ERP_COMPANY' -and $st -match 'ERP_URL')
Check 'it reads paid to date from SAP' ($st -match 'PaidToDate')
$o = Invoke-Xsl 'step5-invoice\sql.xsl' (Msg (Event '812' '24')) 'atom0'
$st = XS $o '//Sql/Statement'
Check 'a payment event reads the invoices the payment was applied to' ($st -match 'RCT2 R WHERE R\.DocNum = 812 AND R\.InvType = 13')
$o = Invoke-Xsl 'step5-invoice\sql.xsl' (Msg (Event '1; DROP TABLE OINV' '13')) 'atom0'
Check 'a key that is not a number queries nothing' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS DocEntry')
$o = Invoke-Xsl 'step5-invoice\sql.xsl' (Msg (Event '557' '17')) 'atom0'
Check 'any other object queries nothing' ((XS $o '//Sql/Statement').Trim() -eq 'SELECT TOP 0 1 AS DocEntry')

# ---------------------------------------------------------------- final
function Inv { param([hashtable] $Set = @{})
	$r = [ordered]@{ DocEntry = '9559'; DocNum = '560'; CardCode = 'C-1648'; PostingDate = '2026-10-31'; DueDate = '2026-11-30'
		DocTotal = '975792.000000'; PaidToDate = '100000.000000'; DocStatus = 'O'; Cancelled = 'N'
		Enabled = 'Y'; Company = 'Manna Treads'; ErpUrl = 'https://mannarubber.m.frappe.cloud/' }
	foreach ($k in $Set.Keys) { $r[$k] = $Set[$k] }
	return $r }

$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '9559' '13'), (Rows 'atom1' @((Inv))))) 'atom2'
Check 'an invoice with the setting on is sent' ((XS $o '//Decision/Send') -eq 'Y')
Check 'it goes to manna_sap_invoice_sync, without a double slash' ((XS $o '//Decision/Url') -eq 'https://mannarubber.m.frappe.cloud/api/method/manna_sap_invoice_sync')
$body = XS $o '//Decision/Body'
$j = $body | ConvertFrom-Json
Check 'the body is valid JSON with the company' ($j.company -eq 'Manna Treads') $body
Check 'it carries the DocEntry, total and paid as numbers' ($j.invoices[0].doc_entry -eq 9559 -and $j.invoices[0].total -eq 975792 -and $j.invoices[0].paid -eq 100000) $body
Check 'it carries the customer code, dates and status' ($j.invoices[0].card_code -eq 'C-1648' -and $j.invoices[0].due_date -eq '2026-11-30' -and $j.invoices[0].status -eq 'O')

$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '812' '24'), (Rows 'atom1' @((Inv), (Inv @{ DocEntry = '9560'; DocNum = '561'; CardCode = 'C-1183' }))))) 'atom2'
$j = (XS $o '//Decision/Body') | ConvertFrom-Json
Check 'a payment over two invoices sends both' ($j.invoices.Count -eq 2 -and $j.invoices[1].doc_entry -eq 9560)

$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '9559' '13'), (Rows 'atom1' @((Inv @{ CardCode = 'C-"1\x' }))))) 'atom2'
$j = (XS $o '//Decision/Body') | ConvertFrom-Json
Check 'quotes and backslashes in a code stay valid JSON' ($j.invoices[0].card_code -eq 'C-"1\x')

$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '9559' '13'), (Rows 'atom1' @((Inv @{ Enabled = 'N' }))))) 'atom2'
Check 'nothing is sent while ERP_INVOICE_SYNC is not Y' ((XS $o '//Decision/Send') -eq 'N' -and (XS $o '//Decision/Reason') -match 'ERP_INVOICE_SYNC')
$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '9559' '13'), (Rows 'atom1' @((Inv @{ ErpUrl = '' }))))) 'atom2'
Check 'nothing is sent without ERP_URL, and it says so' ((XS $o '//Decision/Send') -eq 'N' -and (XS $o '//Decision/Reason') -match 'ERP_URL')
$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '812' '24'), (Rows 'atom1' @()))) 'atom2'
Check 'a payment on account (no invoice) sends nothing' ((XS $o '//Decision/Send') -eq 'N')
$o = Invoke-Xsl 'step5-invoice\final.xsl' (Msg @((Event '9559' '13'), (Rows 'atom1' @((Inv @{ Cancelled = 'Y' }))))) 'atom2'
$j = (XS $o '//Decision/Body') | ConvertFrom-Json
Check 'a cancelled invoice is sent so ERPNext can remove it' ((XS $o '//Decision/Send') -eq 'Y' -and $j.invoices[0].cancelled -eq 'Y')

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
