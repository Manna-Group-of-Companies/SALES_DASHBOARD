<#
  Offline proof of each package's two XSLs, the way B1if will run them:
    atom1 on a B1if-shaped message (with a B1 event key for the event packages)
      -> the statement, run with sqlcmd on the local copy of the sender's database
      -> the rows, wrapped as Call SQL's result under Payload id="atom2"
    atom3 on that -> the JSON body, written to out\<package>\body.json
  Then test_bodies.py posts each body to the LOCAL ERPNext as a dry run.

    powershell -File Test-Packages.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Remove-Item Env:SQLCMDUSER, Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue

# package -> local database standing in for its sender, and the event key to try
$cases = @(
    @{ Pkg = 'Z.erpcust';  Db = 'CLONE_MANNA_TREADS';     Key = 'C-1052' },
    @{ Pkg = 'Z.erpitem';  Db = 'CLONE_MANNA_TREADS';     Key = 'I-1048' },
    @{ Pkg = 'Z.erpstock'; Db = 'LIVE8_HITECH_PRETREADS'; Key = $null },
    @{ Pkg = 'Z.erpstatht'; Db = 'LIVE8_HITECH_PRETREADS'; Key = $null },
    @{ Pkg = 'Z.erpstatmt'; Db = 'CLONE_MANNA_TREADS';    Key = $null }
)

function Invoke-Xsl([string]$xslPath, [xml]$doc, [string]$atom) {
    $x = New-Object System.Xml.Xsl.XslCompiledTransform
    $x.Load($xslPath)
    $args2 = New-Object System.Xml.Xsl.XsltArgumentList
    $args2.AddParam('atom', '', $atom)
    $sw = New-Object System.IO.StringWriter
    $x.Transform($doc, $args2, $sw)
    [xml]$sw.ToString()
}

$fail = 0
foreach ($c in $cases) {
    $d = Join-Path $here "out\$($c.Pkg)"
    $trigger = if ($c.Key) { "<vpf:Payload Role='T'><b1e:event xmlns:b1e='urn:com.sap.b1i.sim:b1event'><keys><key><name>Code</name><value>$($c.Key)</value></key></keys></b1e:event></vpf:Payload>" } else { '' }
    [xml]$msg = "<vpf:Msg xmlns:vpf='urn:com.sap.b1i.vplatform:entity'><vpf:Header/><vpf:Body>$trigger</vpf:Body></vpf:Msg>"
    $m1 = Invoke-Xsl (Join-Path $d 'atom1.xsl') $msg 'atom1'
    $ns = New-Object System.Xml.XmlNamespaceManager($m1.NameTable); $ns.AddNamespace('vpf', 'urn:com.sap.b1i.vplatform:entity')
    $stmt = $m1.SelectSingleNode("/vpf:Msg/vpf:Body/vpf:Payload[@id='atom1']/Sql/Statement", $ns).InnerText
    if ($stmt.TrimStart() -notmatch '^SELECT') { Write-Host "FAIL $($c.Pkg): statement does not start with SELECT" -ForegroundColor Red; $fail++; continue }
    # sqlcmd's XML output gives the rows as <row col="..."/>; turn them into Call SQL's <Row><col>..</col></Row>.
    # The local copies predate the pick list's Confirmed field (U_Confirmed, made
    # on TEST and live by hand); stand it in so the rest of the statement is proved.
    $hasField = (sqlcmd -E -C -S localhost -d $c.Db -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('OPKL') AND name = 'U_Confirmed'") -join ''
    if ($hasField.Trim() -eq '0') { $stmt = $stmt -replace "ISNULL\(Q\.U_Confirmed, 'N'\)", "'N'" }
    $tmp = Join-Path $d 'stmt.sql'
    "SET NOCOUNT ON;`r`n:XML ON`r`n$stmt FOR XML RAW('row'), ELEMENTS XSINIL, ROOT('rows')" | Set-Content $tmp -Encoding UTF8
    $raw = (sqlcmd -E -C -S localhost -d $c.Db -i $tmp -y 0) -join ''
    if ($LASTEXITCODE -ne 0 -or $raw -match 'Msg \d+, Level') { Write-Host "FAIL $($c.Pkg): SQL error: $raw" -ForegroundColor Red; $fail++; continue }
    [xml]$rx = if ($raw.Trim()) { $raw } else { '<rows/>' }
    $rowsXml = ($rx.rows.ChildNodes | ForEach-Object {
        '<Row>' + (($_.ChildNodes | ForEach-Object { "<$($_.LocalName)>" + [System.Security.SecurityElement]::Escape($_.InnerText) + "</$($_.LocalName)>" }) -join '') + '</Row>'
    }) -join ''
    [xml]$msg3 = "<vpf:Msg xmlns:vpf='urn:com.sap.b1i.vplatform:entity'><vpf:Header/><vpf:Body>$trigger<vpf:Payload id='atom2'><ResultSet>$rowsXml</ResultSet></vpf:Payload></vpf:Body></vpf:Msg>"
    $m3 = Invoke-Xsl (Join-Path $d 'atom3.xsl') $msg3 'atom3'
    $ns3 = New-Object System.Xml.XmlNamespaceManager($m3.NameTable); $ns3.AddNamespace('vpf', 'urn:com.sap.b1i.vplatform:entity')
    $http = $m3.SelectSingleNode("/vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http", $ns3)
    [IO.File]::WriteAllText((Join-Path $d 'body.json'), $http.Body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("ok   {0,-11} rows {1,5}  -> {2}" -f $c.Pkg, $http.Count, $http.Endpoint)
}
if ($fail) { exit 1 }
