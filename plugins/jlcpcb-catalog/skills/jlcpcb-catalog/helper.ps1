# jlcpcb-catalog skill -- JLCPCB component-search API client.
#
# Loading (avoids ExecutionPolicy issues):
#   Get-Content "$HOME\.claude\skills\jlcpcb-catalog\helper.ps1" -Raw | Invoke-Expression
#
# Path override:
#   $env:JLC_CATALOG_PATH = 'D:\custom\basic-parts.md'  (set BEFORE loading)
#
# Public functions:
#   Search-Jlc, Get-JlcByCode, Search-JlcPassive   -- live API queries
#   Get-JlcCatalog                                  -- read offline catalog (warns when stale)
#   Update-JlcCatalog                               -- refresh catalog in place (parallel)
#   Test-JlcCatalogFreshness                        -- staleness check (>14 days warns)
#   Invoke-JlcBulkLookup                            -- bulk parallel lookup primitive

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:JlcSearchUrl = 'https://jlcpcb.com/api/overseas-pcb-order/v1/shoppingCart/smtGood/selectSmtComponentList'

# Find basic-parts.md across legacy local-skill and plugin-cache install layouts.
# Override with $env:JLC_CATALOG_PATH if you want to point it elsewhere.
function script:Find-JlcCatalog {
    if ($env:JLC_CATALOG_PATH) { return $env:JLC_CATALOG_PATH }
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'basic-parts.md'))) {
        return Join-Path $PSScriptRoot 'basic-parts.md'
    }
    $candidates = @(
        "$HOME\.claude\skills\jlcpcb-catalog\basic-parts.md"
    )
    $cacheBase = "$HOME\.claude\plugins\cache"
    if (Test-Path $cacheBase) {
        Get-ChildItem $cacheBase -Recurse -Filter 'basic-parts.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*jlcpcb-catalog*' } |
            ForEach-Object { $candidates += $_.FullName }
    }
    $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$script:CatalogPath  = Find-JlcCatalog
$script:StalenessDays = 14

# ====== live API ======================================================

function script:Invoke-JlcApi {
    # PS 5.1's Invoke-RestMethod decodes responses as ISO-8859-1 by default,
    # mangling JLCPCB's UTF-8 Chinese / Ω text. Use WebClient with explicit UTF-8.
    param([Parameter(Mandatory)] [string] $Body)
    $wc = [System.Net.WebClient]::new()
    try {
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
        $wc.UploadString($script:JlcSearchUrl, 'POST', $Body) | ConvertFrom-Json
    } finally { $wc.Dispose() }
}

function Search-Jlc {
    <#
    .SYNOPSIS
      Query JLCPCB's component-search API. Best for MPNs and C-numbers;
      parametric strings ("10K 0402") return whatever's most popular.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)] [string] $Keyword,
        [ValidateSet('','base','expand')] [string] $Library = '',
        [int] $PageSize = 10,
        [switch] $Raw
    )
    $body = @{
        keyword              = $Keyword
        currentPage          = 1
        pageSize             = $PageSize
        componentLibraryType = $Library
    } | ConvertTo-Json -Compress
    $resp = Invoke-JlcApi -Body $body
    if ($Raw) { return $resp }
    if ($resp.code -ne 200) {
        Write-Error "JLCPCB API code $($resp.code): $($resp.message)"
        return
    }
    $kw = $Keyword.Trim()
    $resp.data.componentPageInfo.list | ForEach-Object {
        $exact = ($_.componentModelEn -ieq $kw) -or ($_.componentCode -ieq $kw)
        [PSCustomObject]@{
            Code   = $_.componentCode
            Lib    = $_.componentLibraryType
            Stock  = $_.stockCount
            Brand  = $_.componentBrandEn
            MPN    = $_.componentModelEn
            Desc   = $_.erpComponentName
            Price1 = if ($_.componentPrices) { $_.componentPrices[0].productPrice } else { $null }
            Pref   = $_.preferredComponentFlag
            MinAsm = $_.leastPatchNumber
            DataSheet = $_.dataManualUrl
            ExactMatch = $exact
        }
    } | Sort-Object `
        @{Expression='ExactMatch'; Descending=$true}, `
        @{Expression={if ($_.Lib -eq 'base') { 0 } else { 1 }}; Descending=$false}, `
        @{Expression='Pref'; Descending=$true}, `
        @{Expression='Stock'; Descending=$true}
}

function Get-JlcByCode {
    [CmdletBinding()] param([Parameter(Mandatory, Position=0)] [string] $Code)
    Search-Jlc -Keyword $Code -PageSize 1 | Where-Object { $_.Code -eq $Code }
}

function Search-JlcPassive {
    <#
    .SYNOPSIS
      Search by manufacturer parametric MPN (Yageo RC, Samsung CL05, etc.).
      Use this instead of "10K 0402" -- the API does fuzzy text matching, not parametrics.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Mpn)
    $r = Search-Jlc -Keyword $Mpn -Library base -PageSize 3
    if (-not $r) { $r = Search-Jlc -Keyword $Mpn -PageSize 3 }
    $r
}

# ====== bulk parallel lookup ==========================================

function Invoke-JlcBulkLookup {
    <#
    .SYNOPSIS
      Resolve many C-numbers in parallel via runspace pool. Used by
      Update-JlcCatalog. Returns one object per input code.
    .EXAMPLE
      Invoke-JlcBulkLookup -Codes 'C17168','C25744','C307331'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Codes,
        [int] $Throttle = 10,
        [int] $TimeoutSec = 30
    )
    $url = $script:JlcSearchUrl
    $pool = [runspacefactory]::CreateRunspacePool(1, $Throttle)
    $pool.Open()
    $script = {
        param($code, $url, $timeoutSec)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $body = @{ keyword=$code; currentPage=1; pageSize=3; componentLibraryType='' } | ConvertTo-Json -Compress
            $wc = [System.Net.WebClient]::new()
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
            $resp = $wc.UploadString($url, 'POST', $body) | ConvertFrom-Json
            $wc.Dispose()
            $hit = $resp.data.componentPageInfo.list | Where-Object { $_.componentCode -eq $code } | Select-Object -First 1
            if ($hit) {
                [PSCustomObject]@{
                    Code = $code
                    Mpn = $hit.componentModelEn
                    Library = $hit.componentLibraryType
                    Stock = $hit.stockCount
                    Desc = $hit.erpComponentName
                    Brand = $hit.componentBrandEn
                    Found = $true
                }
            } else {
                [PSCustomObject]@{ Code = $code; Found = $false; Reason = 'no exact match in result list' }
            }
        } catch {
            [PSCustomObject]@{ Code = $code; Found = $false; Reason = $_.Exception.Message }
        }
    }
    $jobs = foreach ($code in $Codes) {
        $ps = [powershell]::Create().AddScript($script).AddArgument($code).AddArgument($url).AddArgument($TimeoutSec)
        $ps.RunspacePool = $pool
        [PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() }
    }
    foreach ($j in $jobs) {
        try { $j.Pipe.EndInvoke($j.Handle) } finally { $j.Pipe.Dispose() }
    }
    $pool.Close(); $pool.Dispose()
}

# ====== sanity / freshness ============================================

function Test-JlcRowMatch {
    <#
    .SYNOPSIS
      Cross-check a catalog row's authored Value/Package against the
      API's MPN and erpComponentName. Returns array of issue strings;
      empty = consistent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Mpn,
        [Parameter(Mandatory)] [string] $Desc,
        [Parameter(Mandatory)] [string] $ClaimedValue,
        [Parameter(Mandatory)] [string] $ClaimedPackage
    )
    $issues = @()

    # Package check via MPN prefix
    $mpnSize = $null
    switch -regex ($Mpn) {
        '^CL05'      { $mpnSize = '0402' }
        '^CL10'      { $mpnSize = '0603' }
        '^CL21'      { $mpnSize = '0805' }
        '^CL31'      { $mpnSize = '1206' }
        '^CC0402'    { $mpnSize = '0402' }
        '^CC0603'    { $mpnSize = '0603' }
        '^CC0805'    { $mpnSize = '0805' }
        '^(0201|0402|0603|0805|1206|1210)' { $mpnSize = $matches[1] }
    }
    if ($mpnSize -and $ClaimedPackage -match '(\d{4})$') {
        $claimedSize = $matches[1]
        if ($mpnSize -ne $claimedSize) {
            $issues += "package: claimed $ClaimedPackage but MPN '$Mpn' implies $mpnSize"
        }
    }

    # Value check via erpDesc substring
    if ($ClaimedValue -match '^(\d+(?:\.\d+)?)([KkMmRr]?)$') {
        # Resistor-style ("10K", "100R", "0", "1M")
        $num = $matches[1]; $mult = $matches[2].ToUpper()
        $expected = switch ($mult) {
            'K' { "${num}kΩ" }
            'M' { "${num}MΩ" }
            'R' { "${num}Ω" }
            ''  { if ($num -eq '0') { '0Ω' } else { "${num}Ω" } }
        }
        if ($Desc -notlike "*$expected*") {
            $issues += "value: claimed $ClaimedValue (≈$expected) but erpDesc says '$Desc'"
        }
    } elseif ($ClaimedValue -match '^(\d+(?:\.\d+)?\s*(p|n|u|μ)F)') {
        # Cap value -- use captured prefix as needle (handles "100nF/16V" too)
        $needle = $matches[1] -replace 'μ', 'u'
        $altNeedle = $needle -replace 'uF', 'μF'
        if (($Desc -notlike "*$needle*") -and ($Desc -notlike "*$altNeedle*")) {
            $issues += "value: claimed $ClaimedValue but erpDesc says '$Desc'"
        }
    }
    # else: punt -- unknown format

    return ,$issues
}

function Test-JlcCatalogFreshness {
    <#
    .SYNOPSIS
      Read the "Last refreshed: YYYY-MM-DD" line in basic-parts.md and
      return age in days (or $null if not parseable). Warns when stale.
    #>
    [CmdletBinding()]
    param(
        [string] $MdPath = $script:CatalogPath,
        [int] $WarnAfterDays = $script:StalenessDays,
        [switch] $Quiet
    )
    if (-not (Test-Path $MdPath)) { return $null }
    $line = Get-Content $MdPath | Where-Object { $_ -match '^Last refreshed:\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1
    if (-not $line) { return $null }
    $null = $line -match '(\d{4}-\d{2}-\d{2})'
    $stamp = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd', $null)
    $ageDays = [int]([datetime]::Now - $stamp).TotalDays
    if (-not $Quiet -and $ageDays -ge $WarnAfterDays) {
        Write-Warning "JLCPCB catalog is $ageDays days old (refreshed $($matches[1])). Run Update-JlcCatalog to refresh -- Basic-Part status and stock can drift."
    }
    return $ageDays
}

# ====== catalog read / write ==========================================

$script:RowRegex      = '^\|\s*(C\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$'
$script:RowRegexAuthor = '^\|\s*(C\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*[^|]*\s*\|\s*[^|]*\s*\|\s*[^|]*\s*\|\s*([^|]*?)\s*\|\s*$'

function Get-JlcCatalog {
    <#
    .SYNOPSIS
      Look up a value/package in the offline catalog (basic-parts.md).
      Warns when the catalog is older than 14 days.
    .EXAMPLE
      Get-JlcCatalog -Value '10K' -Package R0402
    #>
    param(
        [Parameter(Mandatory)] [string] $Value,
        [string] $Package = '',
        [string] $MdPath = $script:CatalogPath,
        [switch] $Quiet
    )
    if (-not (Test-Path $MdPath)) {
        if (-not $Quiet) { Write-Warning "Catalog not found: $MdPath. Run Update-JlcCatalog or set `$env:JLC_CATALOG_PATH." }
        return
    }
    $null = Test-JlcCatalogFreshness -MdPath $MdPath -Quiet:$Quiet
    Get-Content $MdPath | ForEach-Object {
        if ($_ -match $script:RowRegex) {
            $row = [PSCustomObject]@{
                Code = $matches[1]; Value = $matches[2]; Package = $matches[3]
                MPN = $matches[4]; Library = $matches[5]; Stock = $matches[6]; Notes = $matches[7]
            }
            if ($row.Value -ieq $Value -and ([string]::IsNullOrEmpty($Package) -or $row.Package -ieq $Package)) {
                $row
            }
        }
    }
}

function Format-StockShort {
    param([Parameter(Mandatory)] [int64] $N)
    if ($N -ge 1000000) { '{0:N1}M' -f ($N / 1e6) }
    elseif ($N -ge 1000) { '{0:N0}K' -f ($N / 1e3) }
    else { '{0:N0}' -f $N }
}

function Update-JlcCatalog {
    <#
    .SYNOPSIS
      Refresh basic-parts.md in place. Parallel API resolution (~3-4s
      vs. 30s sequential), Basic→Extended drift detection, MPN-rename
      detection, and Value/Package sanity check via Test-JlcRowMatch.
    #>
    [CmdletBinding()]
    param(
        [string] $MdPath = $script:CatalogPath,
        [int] $Throttle = 10
    )
    if (-not (Test-Path $MdPath)) { Write-Error "Catalog file not found: $MdPath"; return }

    # Parse -- collect (code, value, package, notes, oldMpn, oldLib) from each authored row
    $lines = Get-Content $MdPath
    $rows = New-Object 'System.Collections.Generic.List[PSCustomObject]'
    foreach ($ln in $lines) {
        if ($ln -match $script:RowRegex) {
            $rows.Add([PSCustomObject]@{
                Code = $matches[1]; Value = $matches[2]; Package = $matches[3]
                OldMpn = $matches[4]; OldLib = $matches[5]; OldStock = $matches[6]; Notes = $matches[7]
            })
        }
    }
    if ($rows.Count -eq 0) { Write-Warning "No catalog rows found in $MdPath"; return }

    Write-Host "Refreshing $($rows.Count) catalog rows in parallel (throttle=$Throttle)..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resolved = Invoke-JlcBulkLookup -Codes $rows.Code -Throttle $Throttle
    $sw.Stop()
    Write-Host "  API calls completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

    $byCode = @{}
    foreach ($r in $resolved) { $byCode[$r.Code] = $r }

    # Build new lines + collect drift / sanity findings
    $newLines = New-Object 'System.Collections.Generic.List[string]'
    $stats = [PSCustomObject]@{ Total=$rows.Count; Drift=0; MpnDrift=0; NotFound=0; LowStock=0; Mismatch=0 }
    $rowIdx = 0
    foreach ($ln in $lines) {
        if ($ln -match $script:RowRegex) {
            $r = $rows[$rowIdx]; $rowIdx++
            $api = $byCode[$r.Code]
            if (-not $api -or -not $api.Found) {
                Write-Warning "  $($r.Code) NOT FOUND ($($api.Reason))"
                $stats.NotFound++
                $newLines.Add($ln)
                continue
            }
            # Sanity: value/package vs API
            $issues = Test-JlcRowMatch -Mpn $api.Mpn -Desc $api.Desc -ClaimedValue $r.Value -ClaimedPackage $r.Package
            foreach ($i in $issues) {
                Write-Warning "  $($r.Code) [$($r.Value) $($r.Package)] $i"
                $stats.Mismatch++
            }
            # Drift detection
            if ($api.Library -ne 'base') {
                Write-Warning "  $($r.Code) library drift: was $($r.OldLib), now $($api.Library)"
                $stats.Drift++
            }
            if ($r.OldMpn -and $r.OldMpn -ne $api.Mpn) {
                Write-Warning "  $($r.Code) MPN drift: was '$($r.OldMpn)', now '$($api.Mpn)'"
                $stats.MpnDrift++
            }
            if ($api.Stock -lt 1000) {
                Write-Warning "  $($r.Code) low stock: $($api.Stock)"
                $stats.LowStock++
            }
            $stockStr = Format-StockShort -N $api.Stock
            $newLines.Add("| $($r.Code) | $($r.Value) | $($r.Package) | $($api.Mpn) | $($api.Library) | $stockStr | $($r.Notes) |")
        } elseif ($ln -match '^Last refreshed:') {
            $newLines.Add("Last refreshed: $(Get-Date -Format 'yyyy-MM-dd')")
        } else {
            $newLines.Add($ln)
        }
    }

    $newLines | Set-Content -Path $MdPath -Encoding UTF8
    Write-Host ""
    Write-Host "Refreshed: $($stats.Total) rows. Drift=$($stats.Drift) MpnDrift=$($stats.MpnDrift) NotFound=$($stats.NotFound) LowStock=$($stats.LowStock) Mismatch=$($stats.Mismatch)"
}
