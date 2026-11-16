<#
.SYNOPSIS
  Offline proof of step 6 (delivery dates, ..\step6-dates), end to end the way
  B1if will run it - with no SAP and no B1if.

.DESCRIPTION
  Two scratch databases are made on the LOCAL SQL Server (Windows login),
  holding only the columns the step reads, and seeded with one small world:
  orders that agree, an order moved whole, an order with one item moved (on a
  sales order with a deleted line and a closed line), a split line, and the
  ones the step must not touch. Then, as B1if does:

      sql-ht.xsl  -> its statement, run on the Hi-Tech scratch database
      sql-mt.xsl  -> on those rows; its statement, run on the Manna Treads one
      final.xsl   -> on both row sets: the decision and the two updates
      bom.xsl     -> what each B1 Object atom is handed

  and the output is held to the rule in each check's name. Both databases are
  dropped at the end, pass or fail.

      powershell -NoProfile -File sap-b1if\tests\Test-DatesStep.ps1

  What this cannot prove is B1if's own update call - whether "Synchronous
  Update" with these rows changes the lines meant. That needs the package
  imported on the server and one order on the TEST companies.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Remove-Item Env:SQLCMDUSER, Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
$script:fail = 0
$script:pass = 0
$HT = 'B1IF_DATES_SCRATCH_HT'
$MT = 'B1IF_DATES_SCRATCH_MT'
$vpf = 'urn:com.sap.b1i.vplatform:entity'

function Check {
	param([string] $Name, [bool] $Ok, [string] $Detail = '')
	if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

function Sql {
	param([string] $Db, [string] $Text)
	$tmp = Join-Path $env:TEMP ("b1if-dates-" + [guid]::NewGuid().ToString('N') + '.sql')
	[IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($true)))
	try {
		$out = (sqlcmd -E -C -S localhost -d $Db -b -i $tmp -y 0) -join ''
		if ($LASTEXITCODE -ne 0 -or $out -match 'Msg \d+, Level') { throw "SQL failed on ${Db}: $out" }
		return $out
	} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# The rows a statement returns, as Call SQL hands them on: <Row><col>..</col></Row>.
function Rows {
	param([string] $Db, [string] $Statement)
	$raw = Sql $Db ("SET NOCOUNT ON;`r`n:XML ON`r`n" + $Statement.Trim() + " FOR XML RAW('row'), ELEMENTS XSINIL, ROOT('rows')")
	if (-not $raw.Trim()) { return '' }
	[xml] $rx = $raw
	return ($rx.rows.ChildNodes | ForEach-Object {
		'<Row>' + (($_.ChildNodes | ForEach-Object { "<$($_.LocalName)>" + [System.Security.SecurityElement]::Escape($_.InnerText) + "</$($_.LocalName)>" }) -join '') + '</Row>'
	}) -join ''
}

function Invoke-Xsl {
	param([string] $Xsl, [string] $Xml, [string] $Atom, [hashtable] $Params = @{})
	$t = New-Object System.Xml.Xsl.XslCompiledTransform
	$t.Load((Join-Path $root $Xsl))
	$a = New-Object System.Xml.Xsl.XsltArgumentList
	$a.AddParam('atom', '', $Atom)
	foreach ($k in $Params.Keys) { $a.AddParam($k, '', [string] $Params[$k]) }
	$r = New-Object System.Xml.XmlDocument
	$r.LoadXml($Xml)
	$sw = New-Object System.IO.StringWriter
	$t.Transform($r, $a, $sw)
	$o = New-Object System.Xml.XmlDocument
	$o.LoadXml($sw.ToString())
	return $o
}

function Msg { param([string[]] $Payloads) return "<vpf:Msg xmlns:vpf=`"$vpf`"><vpf:Header/><vpf:Body>$($Payloads -join '')</vpf:Body></vpf:Msg>" }
function Payload { param([string] $Id, [string] $RowsXml) return "<vpf:Payload Role=`"X`" id=`"$Id`"><ResultSet>$RowsXml</ResultSet></vpf:Payload>" }
function XS { param($Doc, [string] $Path) $n = $Doc.SelectSingleNode($Path); if ($n) { return $n.InnerText } return $null }
function Lines { param($Doc, [string] $Part)
	return (($Doc.SelectNodes("//Decision/$Part/BOM/BO/Document_Lines/row") | ForEach-Object { $_.SelectSingleNode('LineNum').InnerText + ':' + $(if ($_.SelectSingleNode('ShipDate')) { $_.SelectSingleNode('ShipDate').InnerText } else { '-' }) }) -join ' ')
}

# One whole run. $Turn stands in for the clock: which of the pairs that differ this run takes.
function Run {
	param([int] $Turn = 0)
	$m1 = Invoke-Xsl 'step6-dates\sql-ht.xsl' (Msg @()) 'atom1'
	$htStmt = XS $m1 '//Sql/Statement'
	$htRows = Rows $HT $htStmt
	$m3 = Invoke-Xsl 'step6-dates\sql-mt.xsl' (Msg @((Payload 'atom2' $htRows))) 'atom3'
	$mtStmt = (XS $m3 '//Sql/Statement').Replace("DATEDIFF(MINUTE, '20260101', GETDATE())", "$Turn")
	$mtRows = Rows $MT $mtStmt
	$m5 = Invoke-Xsl 'step6-dates\final.xsl' (Msg @((Payload 'atom2' $htRows), (Payload 'atom4' $mtRows))) 'atom5'
	return @{ HtStmt = $htStmt; HtRows = $htRows; MtStmt = $mtStmt; MtRows = $mtRows; Sent = (XS $m3 '//Sql/Count'); Out = $m5 }
}

$tables = @"
CREATE TABLE ORDR (DocEntry int, DocNum int, CANCELED char(1), DocStatus char(1), DocDueDate datetime, UpdateDate datetime, U_MannaMtPo nvarchar(11));
CREATE TABLE RDR1 (DocEntry int, LineNum int, VisOrder int, ItemCode nvarchar(50), LineStatus char(1), ShipDate datetime);
CREATE TABLE OPOR (DocEntry int, DocNum int, CANCELED char(1), DocStatus char(1), DocDueDate datetime, U_MannaMtSo nvarchar(11));
CREATE TABLE POR1 (DocEntry int, LineNum int, VisOrder int, ItemCode nvarchar(50), LineStatus char(1), ShipDate datetime);
CREATE TABLE [@MANNA_IC] (Code nvarchar(50), U_Value nvarchar(100));
"@

# Hi-Tech. Order 3xx was made for Manna Treads purchase order 1xx.
$seedHt = @"
INSERT [@MANNA_IC] VALUES ('ENABLED', 'Y');
DECLARE @t datetime = CAST(GETDATE() AS date);
INSERT ORDR VALUES
 (301, 9301, 'N', 'O', '20261120', @t, '101'),              -- agrees with Manna Treads
 (302, 9302, 'N', 'O', '20261125', @t, '102'),              -- whole order moved to the 25th
 (303, 9303, 'N', 'O', '20261120', @t, '103'),              -- item B alone moved to the 27th
 (304, 9304, 'N', 'O', '20261130', DATEADD(day, -10, @t), '104'),  -- moved, but not touched for ten days
 (305, 9305, 'Y', 'C', '20261130', @t, '105'),              -- cancelled
 (306, 9306, 'N', 'O', '20261130', @t, 'abc'),              -- not a purchase order number
 (307, 9307, 'N', 'O', '20261120', @t, '107'),              -- item A split: part on the 20th, the rest on the 28th
 (308, 9308, 'N', 'O', '20261130', @t, '108'),              -- Manna Treads' purchase order is cancelled
 (309, 9309, 'N', 'O', '20261130', @t, NULL);               -- keyed by hand, not the flow's
INSERT RDR1 VALUES
 (301, 0, 0, 'A', 'O', '20261120'), (301, 1, 1, 'B', 'O', '20261120'),
 (302, 0, 0, 'A', 'O', '20261125'), (302, 1, 1, 'B', 'O', '20261125'),
 (303, 0, 0, 'A', 'O', '20261120'), (303, 1, 1, 'b', 'O', '20261127'), (303, 2, 2, 'C', 'C', '20261101'),
 (304, 0, 0, 'A', 'O', '20261130'),
 (305, 0, 0, 'A', 'C', '20261130'),
 (306, 0, 0, 'A', 'O', '20261130'),
 (307, 0, 0, 'A', 'O', '20261120'), (307, 1, 1, 'A', 'O', '20261128'),
 (308, 0, 0, 'A', 'O', '20261130'),
 (309, 0, 0, 'A', 'O', '20261130');
"@

# Manna Treads. Purchase order 1xx was made for sales order 2xx.
$seedMt = @"
INSERT [@MANNA_IC] VALUES ('ENABLED', 'Y'), ('DATE_SYNC', 'Y'), ('VENDOR', 'S-1010');
INSERT OPOR VALUES
 (101, 8101, 'N', 'O', '20261120', '201'), (102, 8102, 'N', 'O', '20261120', '202'), (103, 8103, 'N', 'O', '20261120', '203'),
 (104, 8104, 'N', 'O', '20261120', '204'), (105, 8105, 'N', 'O', '20261120', '205'), (107, 8107, 'N', 'O', '20261120', '207'),
 (108, 8108, 'Y', 'C', '20261120', '208');
INSERT POR1 VALUES
 (101, 0, 0, 'A', 'O', '20261120'), (101, 1, 1, 'B', 'O', '20261120'),
 (102, 0, 0, 'A', 'O', '20261120'), (102, 1, 1, 'B', 'O', '20261120'),
 (103, 0, 0, 'A', 'O', '20261120'), (103, 1, 1, 'B', 'O', '20261120'), (103, 2, 2, 'C', 'C', '20261101'),
 (104, 0, 0, 'A', 'O', '20261120'), (105, 0, 0, 'A', 'O', '20261120'),
 (107, 0, 0, 'A', 'O', '20261120'), (108, 0, 0, 'A', 'O', '20261120');
INSERT ORDR (DocEntry, DocNum, CANCELED, DocStatus, DocDueDate) VALUES
 (201, 7201, 'N', 'O', '20261120'), (202, 7202, 'N', 'O', '20261120'), (203, 7203, 'N', 'O', '20261120'),
 (204, 7204, 'N', 'O', '20261120'), (205, 7205, 'N', 'O', '20261120'), (207, 7207, 'N', 'O', '20261128'), (208, 7208, 'N', 'O', '20261120');
-- Sales order 203 once had a line 1 that was deleted: B is LineNum 2, shown second. D is an item Hi-Tech's order does not hold.
INSERT RDR1 VALUES
 (201, 0, 0, 'A', 'O', '20261120'), (201, 1, 1, 'B', 'O', '20261120'),
 (202, 0, 0, 'A', 'O', '20261120'), (202, 1, 1, 'B', 'O', '20261120'),
 (203, 0, 0, 'A', 'O', '20261120'), (203, 2, 1, 'B', 'O', '20261120'), (203, 3, 2, 'C', 'C', '20261101'), (203, 4, 3, 'D', 'O', '20261122'),
 (204, 0, 0, 'A', 'O', '20261120'), (205, 0, 0, 'A', 'O', '20261120'),
 (207, 0, 0, 'A', 'O', '20261128'), (208, 0, 0, 'A', 'O', '20261120');
"@

try {
	foreach ($db in $HT, $MT) { Sql 'master' "IF DB_ID('$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END; CREATE DATABASE [$db];" | Out-Null }
	Sql $HT ($tables + $seedHt) | Out-Null
	Sql $MT ($tables + $seedMt) | Out-Null

	# ------------------------------------------------------------ what Hi-Tech sends
	$r = Run 0
	Check 'the_hitech_statement_starts_with_SELECT_so_Call_SQL_reads_it' ($r.HtStmt.TrimStart() -match '^SELECT')
	Check 'the_manna_statement_starts_with_SELECT' ($r.MtStmt.TrimStart() -match '^SELECT')
	[xml] $h = "<r>$($r.HtRows)</r>"
	$sent = @($h.r.Row | ForEach-Object { "$($_.MtPo)/$($_.ItemCode)/$($_.ShipDate)" })
	Check 'an_open_order_of_the_flow_changed_lately_is_sent_per_item' ($sent -contains '102/A/2026-11-25' -and $sent -contains '103/B/2026-11-27') ($sent -join ' ')
	Check 'an_item_code_is_sent_in_capitals' (-not ($sent -ccontains '103/b/2026-11-27'))
	Check 'a_closed_line_is_not_sent' (-not ($sent | Where-Object { $_ -like '103/C/*' }))
	Check 'an_order_not_touched_for_ten_days_is_not_sent' (-not ($sent | Where-Object { $_ -like '104/*' }))
	Check 'a_cancelled_order_is_not_sent' (-not ($sent | Where-Object { $_ -like '105/*' }))
	Check 'an_order_whose_link_is_not_a_number_is_not_sent' (-not ($sent | Where-Object { $_ -like 'abc/*' }))
	Check 'an_order_keyed_by_hand_is_not_sent' ($sent.Count -eq 8) "$($sent.Count): $($sent -join ' ')"
	Check 'a_split_item_is_sent_once_with_its_later_date' (@($sent | Where-Object { $_ -like '107/*' }).Count -eq 1 -and $sent -contains '107/A/2026-11-28')

	# ------------------------------------------------- which pairs differ, and the turn
	[xml] $m = "<r>$($r.MtRows)</r>"
	Check 'three_pairs_differ_and_the_rows_say_so' ((@($m.r.Row)[0].Waiting) -eq '3') (@($m.r.Row)[0].Waiting)
	$seen = @()
	foreach ($turn in 0, 1, 2) { $seen += (XS (Run $turn).Out '//Decision/MtPo') }
	Check 'each_pair_that_differs_gets_its_turn_by_the_clock' ((($seen | Sort-Object) -join ',') -eq '102,103,107') ($seen -join ',')
	Check 'a_pair_that_agrees_is_never_taken' (-not ($seen -contains '101'))
	Check 'a_cancelled_purchase_order_is_never_taken' (-not ($seen -contains '108'))

	# ------------------------------------------------------- the whole order moved (102)
	$o = (Run 0).Out
	Check 'turn_0_is_purchase_order_102' ((XS $o '//Decision/MtPo') -eq '102')
	Check 'a_moved_order_updates_the_sales_order_by_its_DocEntry' ((XS $o '//Decision/So/CallMethod') -eq 'Synchronous Update' -and (XS $o '//Decision/So/CallObject') -eq '17' -and (XS $o '//Decision/So/CallKeyName') -eq 'DocEntry' -and (XS $o '//Decision/So/CallKey') -eq '202')
	Check 'and_the_purchase_order_by_its_own' ((XS $o '//Decision/Po/CallMethod') -eq 'Synchronous Update' -and (XS $o '//Decision/Po/CallObject') -eq '22' -and (XS $o '//Decision/Po/CallKey') -eq '102')
	Check 'every_line_takes_hitechs_date_in_DI_format' ((Lines $o 'So') -eq '0:20261125 1:20261125' -and (Lines $o 'Po') -eq '0:20261125 1:20261125') ((Lines $o 'So') + ' | ' + (Lines $o 'Po'))
	Check 'the_documents_own_date_is_the_latest_line' ((XS $o '//Decision/So/BOM/BO/Documents/row/DocDueDate') -eq '20261125' -and (XS $o '//Decision/Po/BOM/BO/Documents/row/DocDueDate') -eq '20261125')
	Check 'the_message_says_what_moved' ((XS $o '//Decision/Changes') -match 'sales order 7202: document 2026-11-20 to 2026-11-25; A 2026-11-20 to 2026-11-25; B 2026-11-20 to 2026-11-25;' -and (XS $o '//Decision/Changes') -match 'purchase order 8102:') (XS $o '//Decision/Changes')
	Check 'the_bom_names_the_object' ((XS $o '//Decision/So/BOM/BO/AdmInfo/Object') -eq '17' -and (XS $o '//Decision/Po/BOM/BO/AdmInfo/Object') -eq '22')

	# --------------------------------------------- one item moved, a gap, a closed line (103)
	$o = (Run 1).Out
	Check 'turn_1_is_purchase_order_103' ((XS $o '//Decision/MtPo') -eq '103')
	Check 'one_item_moved_moves_that_line_and_every_line_is_handed_over_numbered_in_shown_order' ((Lines $o 'So') -eq '0:20261120 2:20261127 3:- 4:20261122') (Lines $o 'So')
	Check 'a_closed_line_gets_its_number_and_no_date' ((Lines $o 'Po') -eq '0:20261120 1:20261127 2:-') (Lines $o 'Po')
	Check 'an_open_line_hitech_does_not_hold_keeps_the_date_it_has' ((Lines $o 'So') -match '4:20261122')
	Check 'the_order_is_complete_on_the_later_date' ((XS $o '//Decision/So/BOM/BO/Documents/row/DocDueDate') -eq '20261127')
	Check 'only_the_moved_item_is_named' ((XS $o '//Decision/Changes') -match 'B 2026-11-20 to 2026-11-27' -and (XS $o '//Decision/Changes') -notmatch ' A 2026')

	# ------------------------------- split item; the sales order already agrees (107)
	$o = (Run 2).Out
	Check 'turn_2_is_purchase_order_107' ((XS $o '//Decision/MtPo') -eq '107')
	Check 'a_document_that_already_agrees_is_only_read' ((XS $o '//Decision/So/CallMethod') -eq 'Synchronous Retrieval' -and (XS $o '//Decision/So/CallObject') -eq '2' -and (XS $o '//Decision/So/CallKey') -eq 'S-1010' -and -not $o.SelectSingleNode('//Decision/So/BOM'))
	Check 'while_the_other_of_the_pair_is_updated' ((XS $o '//Decision/Po/CallMethod') -eq 'Synchronous Update' -and (Lines $o 'Po') -eq '0:20261128')

	# ------------------------------------------------ what the B1 Object atoms are handed
	$msg5 = (Run 0).Out.OuterXml
	$b = Invoke-Xsl 'step6-dates\bom.xsl' $msg5 'atom6'
	$nsm = New-Object System.Xml.XmlNamespaceManager($b.NameTable); $nsm.AddNamespace('vpf', $vpf)
	$p6 = $b.SelectSingleNode("/vpf:Msg/vpf:Body/vpf:Payload[@id='atom6']", $nsm)
	Check 'the_atom_is_handed_the_document_and_its_lines_without_AdmInfo' ($p6.SelectNodes('Documents/row').Count -eq 1 -and $p6.SelectNodes('Document_Lines/row').Count -eq 2 -and -not $p6.SelectSingleNode('.//AdmInfo'))
	$b = Invoke-Xsl 'step6-dates\bom.xsl' $msg5 'atom8' @{ part = 'Po' }
	$nsm = New-Object System.Xml.XmlNamespaceManager($b.NameTable); $nsm.AddNamespace('vpf', $vpf)
	Check 'the_purchase_orders_copy_hands_over_the_purchase_order' ($b.SelectNodes("/vpf:Msg/vpf:Body/vpf:Payload[@id='atom8']/Document_Lines/row", $nsm).Count -eq 2)

	# --------------------------------------------------------------------- the switches
	Sql $MT "UPDATE [@MANNA_IC] SET U_Value = 'N' WHERE Code = 'DATE_SYNC'" | Out-Null
	$o = (Run 0).Out
	Check 'DATE_SYNC_not_Y_writes_nothing' ((XS $o '//Decision/Make') -eq 'N' -and (XS $o '//Decision/Reason') -match 'DATE_SYNC is not Y' -and (XS $o '//Decision/So/CallMethod') -eq 'Synchronous Retrieval' -and (XS $o '//Decision/Po/CallMethod') -eq 'Synchronous Retrieval') (XS $o '//Decision/Reason')
	Sql $MT "DELETE [@MANNA_IC] WHERE Code = 'DATE_SYNC'" | Out-Null
	Check 'a_company_that_was_never_given_DATE_SYNC_writes_nothing' ((XS (Run 0).Out '//Decision/Reason') -match 'DATE_SYNC is not Y')
	Sql $MT "INSERT [@MANNA_IC] VALUES ('DATE_SYNC', 'Y'); UPDATE [@MANNA_IC] SET U_Value = 'N' WHERE Code = 'ENABLED'" | Out-Null
	Check 'manna_treads_ENABLED_not_Y_writes_nothing' ((XS (Run 0).Out '//Decision/Reason') -match "Manna Treads' @MANNA_IC ENABLED is not Y")
	Sql $MT "UPDATE [@MANNA_IC] SET U_Value = 'Y' WHERE Code = 'ENABLED'" | Out-Null
	Sql $HT "UPDATE [@MANNA_IC] SET U_Value = 'N' WHERE Code = 'ENABLED'" | Out-Null
	$r = Run 0
	Check 'hitech_ENABLED_not_Y_sends_no_order_and_writes_nothing' ($r.Sent -eq '0' -and (XS $r.Out '//Decision/Reason') -match "Hi-Tech's @MANNA_IC ENABLED is not Y" -and (XS $r.Out '//Decision/So/CallKey') -eq 'S-1010') (XS $r.Out '//Decision/Reason')
	Sql $HT "UPDATE [@MANNA_IC] SET U_Value = 'Y' WHERE Code = 'ENABLED'" | Out-Null

	# ------------------------------------------------------------ nothing left to do
	Sql $MT "UPDATE RDR1 SET ShipDate = '20261125' WHERE DocEntry = 202; UPDATE POR1 SET ShipDate = '20261125' WHERE DocEntry = 102; UPDATE ORDR SET DocDueDate = '20261125' WHERE DocEntry = 202; UPDATE OPOR SET DocDueDate = '20261125' WHERE DocEntry = 102" | Out-Null
	$seen = @(); foreach ($turn in 0, 1) { $seen += (XS (Run $turn).Out '//Decision/MtPo') }
	Check 'a_pair_that_was_updated_is_not_taken_again' ((($seen | Sort-Object) -join ',') -eq '103,107') ($seen -join ',')
	Sql $HT "UPDATE RDR1 SET ShipDate = '20261120' WHERE DocEntry IN (303, 307); UPDATE ORDR SET U_MannaMtPo = '999' WHERE DocEntry = 307" | Out-Null
	Sql $MT "UPDATE POR1 SET ShipDate = '20261128' WHERE DocEntry = 107; UPDATE OPOR SET DocDueDate = '20261128' WHERE DocEntry = 107" | Out-Null
	$o = (Run 0).Out
	Check 'when_every_date_agrees_the_run_says_so_and_only_reads' ((XS $o '//Decision/Make') -eq 'N' -and (XS $o '//Decision/Reason') -match 'already agrees' -and (XS $o '//Decision/So/CallMethod') -eq 'Synchronous Retrieval') (XS $o '//Decision/Reason')
	Sql $HT "UPDATE ORDR SET DocStatus = 'C'" | Out-Null
	$r = Run 0
	Check 'with_no_open_order_the_manna_statement_asks_only_for_the_settings' ($r.Sent -eq '0' -and (XS $r.Out '//Decision/Reason') -match 'no open Hi-Tech order' -and (XS $r.Out '//Decision/Po/CallKey') -eq 'S-1010') (XS $r.Out '//Decision/Reason')

	# ---------------------------------------------- what goes into the statement as text
	$evil = "<Row><MtPo>102</MtPo><SoNum>1</SoNum><ItemCode>A'; DROP TABLE OPOR; --</ItemCode><ShipDate>2026-11-25</ShipDate><Enabled>Y</Enabled></Row>" +
		"<Row><MtPo>1 OR 1=1</MtPo><SoNum>1</SoNum><ItemCode>A</ItemCode><ShipDate>2026-11-25</ShipDate><Enabled>Y</Enabled></Row>" +
		"<Row><MtPo>103</MtPo><SoNum>1</SoNum><ItemCode>A</ItemCode><ShipDate>2026-11-25'--</ShipDate><Enabled>Y</Enabled></Row>" +
		"<Row><MtPo>12.5</MtPo><SoNum>1</SoNum><ItemCode>A</ItemCode><ShipDate>2026-11-25</ShipDate><Enabled>Y</Enabled></Row>"
	$m3 = Invoke-Xsl 'step6-dates\sql-mt.xsl' (Msg @((Payload 'atom2' $evil))) 'atom3'
	$st = XS $m3 '//Sql/Statement'
	Check 'a_quote_in_an_item_code_is_doubled' ($st -match [regex]::Escape("N'A''; DROP TABLE OPOR; --'"))
	Check 'a_link_or_date_that_is_not_one_is_left_out' ((XS $m3 '//Sql/Count') -eq '1' -and $st -notmatch 'OR 1=1' -and $st -notmatch "25'--" -and $st -notmatch '12\.5')
	Rows $MT $st | Out-Null
	Check 'and_the_statement_still_runs_with_the_table_still_there' ((Sql $MT "SET NOCOUNT ON; SELECT COUNT(*) FROM OPOR") -match '\d')
} finally {
	foreach ($db in $HT, $MT) {
		try { Sql 'master' "IF DB_ID('$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END" | Out-Null } catch { Write-Host "could not drop ${db}: $_" -ForegroundColor Yellow }
	}
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
