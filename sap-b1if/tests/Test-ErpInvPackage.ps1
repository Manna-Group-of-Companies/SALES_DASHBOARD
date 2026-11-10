<#
.SYNOPSIS
  Offline checks of the importable step 5 package, exports\Z.erpinv.zip.

      python sap-b1if\step5-invoice\build_package.py
      powershell -NoProfile -File sap-b1if\tests\Test-ErpInvPackage.ps1

  Runs the files as they sit in the zip (atom1 per step, atom3) through
  .NET's XSLT 1.0 engine against hand-made B1if messages, and parses the
  JSON body. No SAP, no B1if, no ERPNext.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$zip = Join-Path $root 'exports\Z.erpinv.zip'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("erpinv-" + [guid]::NewGuid().ToString('N'))
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
$design = Join-Path $tmp 'com.sap.b1i.vplatform.scenarios.design'
$script:fail = 0; $script:pass = 0

function Invoke-Xsl { param([string] $Path, [string] $Xml, [string] $Atom)
	$t = New-Object System.Xml.Xsl.XslCompiledTransform; $t.Load($Path)
	$a = New-Object System.Xml.Xsl.XsltArgumentList; $a.AddParam('atom', '', $Atom)
	$r = New-Object System.Xml.XmlDocument; $r.LoadXml($Xml)
	$sw = New-Object System.IO.StringWriter; $t.Transform($r, $a, $sw)
	$o = New-Object System.Xml.XmlDocument; $o.LoadXml($sw.ToString()); return $o }
function Check { param([string] $Name, [bool] $Ok, [string] $Detail = '')
	if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red } }
function XS { param($Doc, [string] $P) $n = $Doc.SelectSingleNode($P); if ($n) { return $n.InnerText } return $null }

$ns = 'xmlns:vpf="urn:com.sap.b1i.vplatform:entity" xmlns:jdbc="urn:com.sap.b1i.adapter:jdbcadapter" xmlns:b1e="urn:com.sap.b1i.sim:b1event"'
function Event { param([string] $Entry, [string] $Type)
	"<vpf:Payload Role=`"T`"><b1e:b1events><b1e:b1event><b1e:ObjectType>$Type</b1e:ObjectType><b1e:keys><b1e:key><b1e:name>DocEntry</b1e:name><b1e:value>$Entry</b1e:value></b1e:key></b1e:keys></b1e:b1event></b1e:b1events></vpf:Payload>" }
function Rows { param([object[]] $Rows)
	$s = '<vpf:Payload Role="X" id="atom2"><jdbc:ResultSet>'
	foreach ($r in $Rows) { $s += '<jdbc:Row>'; foreach ($k in $r.Keys) { $s += "<jdbc:$k>$([Security.SecurityElement]::Escape([string]$r[$k]))</jdbc:$k>" }; $s += '</jdbc:Row>' }
	$s + '</jdbc:ResultSet></vpf:Payload>' }
function Msg { param([string[]] $P) "<vpf:Msg $ns><vpf:Header/><vpf:Body>$($P -join '')</vpf:Body></vpf:Msg>" }
function Inv { param([hashtable] $Set = @{})
	$r = [ordered]@{ doc_entry = '9559'; doc_num = '560'; card_code = 'C-1648'; posting_date = '2026-10-31'; due_date = '2026-11-30'
		total = '975792.000000'; paid = '100000.000000'; status = 'O'; cancelled = 'N'; enabled = 'Y'; company = 'Manna Treads' }
	foreach ($k in $Set.Keys) { $r[$k] = $Set[$k] }; $r }

try {
	# ------------------------------------------------------------ package
	$x = Get-Content (Join-Path $design 'vBIU.Z.erpinvar\vBIU.xml') -Raw
	Check 'the invoice step fires on A/R invoices (13)' ($x -match '<obj>13</obj>' -and $x -match 'SId="Z.erpinv"')
	$x = Get-Content (Join-Path $design 'vBIU.Z.erpinvpay\vBIU.xml') -Raw
	Check 'the payment step fires on incoming payments (24)' ($x -match '<obj>24</obj>')
	$b = Get-Content (Join-Path $design 'vBIU.Z.erpinvar\vBIU.bfd') -Raw
	Check 'Call SQL runs on the Manna Treads system and reads atom1' ($b -match '#0010000119' -and $b -match "Payload\[@id=&apos;atom1&apos;\]/Sql/Statement")
	$all = Get-ChildItem $tmp -Recurse -File | Get-Content -Raw
	Check 'no credentials in the package' (-not ($all -match '(?i)token [a-z0-9]{6,}:|password|api_secret'))

	# ------------------------------------------------------------ atom1
	$a1inv = Join-Path $design 'vBIU.Z.erpinvar\atom1.xsl'
	$a1pay = Join-Path $design 'vBIU.Z.erpinvpay\atom1.xsl'
	$st = XS (Invoke-Xsl $a1inv (Msg (Event '9559' '13')) 'atom1') '//Sql/Statement'
	Check 'an invoice event reads that invoice' ($st -match 'I\.DocEntry = 9559\b')
	Check 'it reads the switch and company from MANNA_IC' ($st -match 'ERP_INVOICE_SYNC' -and $st -match 'ERP_COMPANY')
	$st = XS (Invoke-Xsl $a1pay (Msg (Event '812' '24')) 'atom1') '//Sql/Statement'
	Check 'a payment event reads the invoices it was applied to' ($st -match 'RCT2 R WHERE R\.DocNum = 812 AND R\.InvType = 13')
	$st = XS (Invoke-Xsl $a1inv (Msg (Event '1; DROP TABLE OINV' '13')) 'atom1') '//Sql/Statement'
	Check 'a key that is not a number queries nothing' ($st.Trim() -eq 'SELECT TOP 0 1 AS doc_entry')

	# ------------------------------------------------------------ atom3
	$a3 = Join-Path $design 'vBIU.Z.erpinvar\atom3.xsl'
	$o = Invoke-Xsl $a3 (Msg (Rows @((Inv), (Inv @{ doc_entry = '9560'; card_code = 'C-"7'; status = 'C'; paid = '975792.000000' })))) 'atom3'
	Check 'it posts to manna_sap_invoice_sync' ((XS $o '//Http/Endpoint') -eq '/api/method/manna_sap_invoice_sync')
	$j = (XS $o '//Http/Body') | ConvertFrom-Json
	Check 'the body is valid JSON with the company' ($j.company -eq 'Manna Treads')
	Check 'every invoice is in it' ($j.invoices.Count -eq 2)
	Check 'amounts are numbers' ($j.invoices[0].total -eq 975792 -and $j.invoices[0].paid -eq 100000)
	Check 'a quote in a code is escaped' ($j.invoices[1].card_code -eq 'C-"7')
	$o = Invoke-Xsl $a3 (Msg (Rows @((Inv @{ enabled = 'N' })))) 'atom3'
	$j = (XS $o '//Http/Body') | ConvertFrom-Json
	Check 'switched off (ERP_INVOICE_SYNC = N) sends an empty list' ($j.invoices.Count -eq 0)
	$o = Invoke-Xsl $a3 (Msg (Rows @())) 'atom3'
	$j = (XS $o '//Http/Body') | ConvertFrom-Json
	Check 'no rows sends an empty list' ($j.invoices.Count -eq 0)
} finally {
	Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
