<#
  Offline proof of Z.erpmore's steps, the way B1if will run them (see Test-Packages.ps1):
    atom1 -> its statement, run with sqlcmd on the local copy of that company
          -> the rows, wrapped as Call SQL's result under Payload id="atom2"
    (a step with a second query: atom6 -> the other company -> Payload id="atom7")
    atom3 -> the JSON body, written to out\Z.erpmore\<step>\body.json
  Then test_more_bodies.py posts each body to the LOCAL ERPNext as a dry run.

    powershell -File Test-More.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Remove-Item Env:SQLCMDUSER, Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
$dbs = @{ mt = 'CLONE_MANNA_TREADS'; ht = 'LIVE8_HITECH_PRETREADS' }
$root = Join-Path $here 'out\Z.erpmore'
$steps = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json

function Invoke-Xsl([string]$xslPath, [xml]$doc, [string]$atom) {
    $x = New-Object System.Xml.Xsl.XslCompiledTransform
    $x.Load($xslPath)
    $a = New-Object System.Xml.Xsl.XsltArgumentList
    $a.AddParam('atom', '', $atom)
    $sw = New-Object System.IO.StringWriter
    $x.Transform($doc, $a, $sw)
    [xml]$sw.ToString()
}

function Get-Rows([string]$xslPath, [string]$atom, [string]$db, [string]$dir) {
    [xml]$msg = "<vpf:Msg xmlns:vpf='urn:com.sap.b1i.vplatform:entity'><vpf:Header/><vpf:Body/></vpf:Msg>"
    $m = Invoke-Xsl $xslPath $msg $atom
    $ns = New-Object System.Xml.XmlNamespaceManager($m.NameTable); $ns.AddNamespace('vpf', 'urn:com.sap.b1i.vplatform:entity')
    $stmt = $m.SelectSingleNode("/vpf:Msg/vpf:Body/vpf:Payload[@id='$atom']/Sql/Statement", $ns).InnerText
    if ($stmt.TrimStart() -notmatch '^SELECT') { throw "statement does not start with SELECT" }
    $tmp = Join-Path $dir "$atom.sql"
    # A UNION cannot carry FOR XML itself, so the statement is wrapped; ORDER BY is not allowed in a derived table.
    $inner = $stmt -replace '(?s)\s+ORDER BY [^()]*$', ''
    "SET NOCOUNT ON;`r`n:XML ON`r`nSELECT * FROM (`r`n$inner`r`n) Q FOR XML RAW('row'), ELEMENTS XSINIL, ROOT('rows')" | Set-Content $tmp -Encoding UTF8
    $raw = (sqlcmd -E -C -S localhost -d $db -i $tmp -y 0) -join ''
    if ($LASTEXITCODE -ne 0 -or $raw -match 'Msg \d+, Level') { throw "SQL error: $($raw.Substring(0, [Math]::Min(400, $raw.Length)))" }
    [xml]$rx = if ($raw.Trim()) { $raw } else { '<rows/>' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $rx.rows.ChildNodes) {
        [void]$sb.Append('<Row>')
        foreach ($c in $r.ChildNodes) { [void]$sb.Append("<$($c.LocalName)>" + [System.Security.SecurityElement]::Escape($c.InnerText) + "</$($c.LocalName)>") }
        [void]$sb.Append('</Row>')
    }
    $sb.ToString()
}

$fail = 0
foreach ($s in $steps) {
    $d = Join-Path $root $s.step
    try {
        $one = Get-Rows (Join-Path $d 'atom1.xsl') 'atom1' $dbs[$s.db] $d
        $two = ''
        if ($s.db2) { $two = "<vpf:Payload id='atom7'><ResultSet>" + (Get-Rows (Join-Path $d 'atom6.xsl') 'atom6' $dbs[$s.db2] $d) + "</ResultSet></vpf:Payload>" }
        [xml]$msg3 = "<vpf:Msg xmlns:vpf='urn:com.sap.b1i.vplatform:entity'><vpf:Header/><vpf:Body><vpf:Payload id='atom2'><ResultSet>$one</ResultSet></vpf:Payload>$two</vpf:Body></vpf:Msg>"
        $m3 = Invoke-Xsl (Join-Path $d 'atom3.xsl') $msg3 'atom3'
        $ns3 = New-Object System.Xml.XmlNamespaceManager($m3.NameTable); $ns3.AddNamespace('vpf', 'urn:com.sap.b1i.vplatform:entity')
        $http = $m3.SelectSingleNode("/vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http", $ns3)
        [IO.File]::WriteAllText((Join-Path $d 'body.json'), $http.Body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("ok   {0,-13} rows {1,5}  {2,8} bytes" -f $s.step, $http.Count, $http.Body.Length)
    } catch {
        Write-Host "FAIL $($s.step): $_" -ForegroundColor Red; $fail++
    }
}
if ($fail) { exit 1 }
