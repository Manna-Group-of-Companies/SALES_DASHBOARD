<#
  A Service Layer session over curl.exe, dot-sourced by the scripts in this
  folder. Built the way sap-tools\Sap-Get.ps1 is, for the same reasons:

    * curl.exe, not Invoke-RestMethod. Windows PowerShell 5.1 sends
      "Expect: 100-continue" and this Service Layer answers any request carrying
      it with an EMPTY-BODY HTTP 500 - Login included. "-H Expect:" removes it.
    * A cookie jar carries B1SESSION and ROUTEID. ROUTEID pins the session to the
      one of ten Service Layer nodes that created it.
    * Close-SapSession belongs in a finally. There are 5 Professional seats,
      shared with the people in the SAP client all day; a session left open
      holds one until the 30-minute idle timeout.
    * Credentials are read from a sync config.json and never printed or logged.
      The login body goes through a temp file that is deleted straight away.
    * Bodies are sent as UTF-8 bytes from a file, never as a PowerShell string.
#>

Set-StrictMode -Version 1.0

$script:SapUS   = [string][char]0x1F
$script:SapUtf8 = New-Object System.Text.UTF8Encoding($false)

function New-SapSession {
    param(
        [Parameter(Mandatory = $true)] [string] $ConfigPath,
        [Parameter(Mandatory = $true)] [string] $CompanyDb
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config not found: $ConfigPath" }
    $raw = [IO.File]::ReadAllText($ConfigPath).TrimStart([char]0xFEFF)
    $sap = ($raw | ConvertFrom-Json).sap
    if (-not $sap -or -not $sap.url -or -not $sap.username -or -not $sap.password) {
        throw "no usable sap.url / sap.username / sap.password in $ConfigPath"
    }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $s = [pscustomobject]@{
        Base      = "$($sap.url)".TrimEnd('/')
        Root      = ([Uri]"$($sap.url)").GetLeftPart([UriPartial]::Authority)
        Curl      = (Get-Command curl.exe).Source
        Jar       = Join-Path $env:TEMP "sap-pricing-$tag.jar"
        Tag       = $tag
        CompanyDb = $CompanyDb
        Open      = $false
    }
    $loginFile = Join-Path $env:TEMP "sap-pricing-$tag-login.json"
    try {
        [IO.File]::WriteAllText($loginFile,
            (@{ CompanyDB = $CompanyDb; UserName = "$($sap.username)"; Password = "$($sap.password)" } | ConvertTo-Json -Compress),
            $script:SapUtf8)
        $r = Invoke-SapCurl -Session $s -Method POST -Url "$($s.Base)/Login" -BodyFile $loginFile -SaveCookies
    } finally {
        Remove-Item -LiteralPath $loginFile -Force -ErrorAction SilentlyContinue
    }
    if ($r.Http -ne '200') {
        Remove-Item -LiteralPath $s.Jar -Force -ErrorAction SilentlyContinue
        $hint = if ($r.Http -eq '500' -and -not "$($r.Body)".Trim()) { ' (empty-body 500: Expect header, or the Service Layer is down)' } else { '' }
        throw ("SAP Login to {0} -> HTTP {1}: {2}{3}" -f $CompanyDb, $r.Http, (Get-SapShort $r.Body), $hint)
    }
    $s.Open = $true
    Write-Host ("SAP login OK: {0}" -f $CompanyDb) -ForegroundColor DarkGray
    return $s
}

function Invoke-SapCurl {
    param($Session, [string] $Method, [string] $Url, [string] $BodyFile, [switch] $SaveCookies)
    $resp = Join-Path $env:TEMP "sap-pricing-$($Session.Tag)-resp.txt"
    $a = @('-k', '-s', '--globoff', '--connect-timeout', '15', '--max-time', '180',
           '-H', 'Expect:', '-H', 'Prefer: odata.maxpagesize=500',
           '-o', $resp, '-w', "%{http_code}$($script:SapUS)%{time_total}", '-X', $Method)
    if ($SaveCookies) { $a += @('-c', $Session.Jar) } else { $a += @('-b', $Session.Jar) }
    if ($BodyFile) { $a += @('-H', 'Content-Type: application/json', '--data-binary', "@$BodyFile") }
    $a += $Url
    $meta = & $Session.Curl @a
    $body = if (Test-Path -LiteralPath $resp) { [IO.File]::ReadAllText($resp); Remove-Item -LiteralPath $resp -Force } else { '' }
    $p = "$meta" -split [regex]::Escape($script:SapUS)
    [pscustomobject]@{ Http = "$($p[0])"; Secs = "$($p[1])"; Body = $body; CurlExit = $LASTEXITCODE }
}

# An unencoded space ends a curl URL, so a $filter would fail before reaching
# SAP. Only the characters that break a URL are encoded.
function ConvertTo-SapUrl {
    param($Session, [string] $Path)
    $u = if ($Path -match '^https?://') { $Path } elseif ($Path.StartsWith('/')) { "$($Session.Root)$Path" } else { "$($Session.Base)/$Path" }
    $i = $u.IndexOf('?')
    if ($i -lt 0) { return $u }
    return $u.Substring(0, $i + 1) + ($u.Substring($i + 1) -replace ' ', '%20' -replace "'", '%27' -replace '"', '%22' -replace '#', '%23')
}

function Get-SapShort([string] $s, [int] $n = 400) {
    $s = ("$s" -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { $s.Substring(0, $n) + ' ...' } else { $s }
}

<# One GET. Returns the parsed JSON, or throws with SAP's own message. #>
function Get-SapOne {
    param($Session, [string] $Path)
    $r = Invoke-SapCurl -Session $Session -Method GET -Url (ConvertTo-SapUrl $Session $Path)
    if ($r.Http -ne '200') { throw ("GET {0} -> HTTP {1}: {2}" -f $Path, $r.Http, (Get-SapShort $r.Body)) }
    return ($r.Body | ConvertFrom-Json)
}

<#
  Every row of a collection, following odata.nextLink. Returned unrolled, so
  callers wrap it: @(Get-SapAll ...). (Returning ", array" instead and then
  wrapping in @() nests it, and an empty result counts as one row.)
#>
function Get-SapAll {
    param($Session, [string] $Path, [int] $MaxPages = 100)
    $rows = New-Object System.Collections.Generic.List[object]
    $next = $Path; $pages = 0
    while ($next) {
        if (++$pages -gt $MaxPages) { throw "GET $Path : more than $MaxPages pages - narrow the filter" }
        $j = Get-SapOne $Session $next
        foreach ($v in @($j.value)) { $rows.Add($v) }
        $next = $null
        foreach ($n in 'odata.nextLink', '@odata.nextLink') { if ($j.PSObject.Properties[$n] -and $j.$n) { $next = [string]$j.$n } }
    }
    return $rows.ToArray()
}

<#
  One write. POST, PATCH or DELETE with an object body. Returns the curl result;
  the caller decides what counts as success (POST 201, PATCH 204).
#>
function Invoke-SapWrite {
    param($Session, [ValidateSet('POST', 'PATCH', 'DELETE')] [string] $Method, [string] $Path, $Body)
    $bodyFile = $null
    try {
        if ($null -ne $Body) {
            $bodyFile = Join-Path $env:TEMP "sap-pricing-$($Session.Tag)-body.json"
            [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 8 -Compress), $script:SapUtf8)
        }
        return Invoke-SapCurl -Session $Session -Method $Method -Url (ConvertTo-SapUrl $Session $Path) -BodyFile $bodyFile
    } finally {
        if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
    }
}

function Close-SapSession {
    param($Session)
    if ($null -eq $Session) { return }
    if ($Session.Open) {
        try {
            $lo = Invoke-SapCurl -Session $Session -Method POST -Url "$($Session.Base)/Logout"
            Write-Host ("SAP logout: HTTP {0}" -f $lo.Http) -ForegroundColor DarkGray
        } catch { }
        $Session.Open = $false
    }
    Remove-Item -LiteralPath $Session.Jar -Force -ErrorAction SilentlyContinue
}
