---
name: jlcpcb-catalog
description: Query JLCPCB and LCSC's parts catalog directly via the public JSON API — resolve MPNs to LCSC C-numbers, check stock and JLCPCB Basic-vs-Extended status, fetch datasheet URLs, and source parts by spec. Use whenever the user mentions JLCPCB, LCSC, "C12345"-style codes, BOM, PCBA, MPN lookup, sourcing, datasheet, or asks "find me a [component] with [specs]".
---

# JLCPCB / LCSC catalog access

## Verification rule (no exceptions)

**When the user asks about a part, hit the API. Every time.** Don't return information from memory, from the catalog file, or from earlier in this conversation. Call `Get-JlcByCode` (or one `curl POST`) and report what the API says *right now*.

This applies to:
- "What's the LCSC code for X?" → API lookup
- "Is C12345 still in stock?" → API lookup
- "Verify the codes in this BOM" → API lookup per row
- Quoting a row from `basic-parts.md` → API lookup (the .md is your *seed list of candidates*, not your truth source)

The user would hit the API themselves rather than trust a cached file. ~1.2s per call; cheap insurance against shipping stale or wrong info.

**If the lookup contradicts your expectation** — the file says Basic but the API says Extended, the MPN doesn't match, stock dropped to zero, package disagrees with the schematic — *don't paper over it.* Spawn a Mode 3 subagent to source the correct part or substitute, then come back with a verified answer.

`basic-parts.md` is still useful for: knowing which C-numbers are candidates for a given (value, package); bulk drift detection via `Update-JlcCatalog`; eyeballing the project's standard passive picks. But it is *not* a substitute for a live lookup when reporting to the user. Past failures from skipping this: C14663 was 0603 not 0402; C1653 was 22pF not 12pF; C24316 didn't exist; C25804 was 0603 not 0402; C25803 was wrong. Five errors shipped before the audit caught them.

## Three modes of use

Pick by the shape of the question:

| Mode | When to use | How |
|---|---|---|
| **Direct** | Known MPN, known C-number, single-shot verify | `Search-Jlc` / `Get-JlcByCode` (one API call) |
| **Catalog** | Common 0402 passive (10K, 100nF, 22pF, ...) | Read `basic-parts.md` once, quote values inline |
| **Parametric subagent** | Open-ended sourcing ("find an ESD diode with 6V breakdown, 0805 or smaller, in stock") | Spawn `general-purpose` Agent with the prompt template below |

BOM creation is **one application** of these modes, not the framing of the skill. See "Workflow: schematic → BOM" near the bottom.

## The API

```
POST https://jlcpcb.com/api/overseas-pcb-order/v1/shoppingCart/smtGood/selectSmtComponentList
Content-Type: application/json

{ "keyword": "ESP32-C6FH4", "currentPage": 1, "pageSize": 10, "componentLibraryType": "" }
```

No auth, no key, no observed rate limit. `componentLibraryType`: `""` = both, `"base"` = Basic only, `"expand"` = Extended only.

**Response key fields** (per `data.componentPageInfo.list[i]`):

| Field | Meaning |
|---|---|
| `componentCode` | LCSC `C12345` code (this is what the BOM CSV needs) |
| `componentLibraryType` | `"base"` (Basic, no setup fee) or `"expand"` (Extended, $3 setup) |
| `stockCount` | JLCPCB-side stock |
| `componentBrandEn` / `componentModelEn` | manufacturer / MPN |
| `erpComponentName` | value description (often Chinese — `100nF ±10% 50V`, `厚膜电阻 10kΩ ±1%`) |
| `componentPrices[]` | tiered pricing, `productPrice` at each `startNumber` |
| `preferredComponentFlag` | "Preferred" Extended part — sometimes a smaller setup-fee surcharge |
| `leastPatchNumber` | minimum board count that can be assembled with this part |
| `dataManualUrl` | datasheet PDF URL |
| `lcscGoodsUrl` / `urlSuffix` | composes to LCSC product page / JLCPCB partdetail page |

**Tie-breakers when picking among results** (in order):

1. Exact MPN/code match in `componentModelEn` or `componentCode`
2. `componentLibraryType == "base"` over `"expand"`
3. `preferredComponentFlag == true` over `false`
4. Higher `stockCount`
5. Lower first-tier price

## Mode 1: Direct lookup — `Search-Jlc`, `Get-JlcByCode`

Load the helpers (works whether the skill is in `~/.claude/skills/` or `~/.claude/plugins/cache/.../jlcpcb-catalog/`, and avoids ExecutionPolicy issues):

```powershell
$helperPath = @(
    "$HOME\.claude\skills\jlcpcb-catalog\helper.ps1",
    (Get-ChildItem "$HOME\.claude\plugins\cache" -Recurse -Filter helper.ps1 -ErrorAction SilentlyContinue |
     Where-Object { $_.FullName -like '*jlcpcb-catalog*' } | Select-Object -First 1 -ExpandProperty FullName)
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
Get-Content $helperPath -Raw | Invoke-Expression
```

Then:

```powershell
Search-Jlc -Keyword 'ESP32-C6FH4'             # MPN search
Search-Jlc -Keyword 'C427602' -PageSize 1     # C-number verify
Get-JlcByCode 'C25744'                        # same, terser
Search-JlcPassive -Mpn 'RC0402FR-0710KL'      # parametric MPN, Basic-first
```

For a one-shot from Bash without PowerShell:

```bash
curl -s -H "Content-Type: application/json" -X POST \
  --data '{"keyword":"ESP32-C6FH4","currentPage":1,"pageSize":3}' \
  "https://jlcpcb.com/api/overseas-pcb-order/v1/shoppingCart/smtGood/selectSmtComponentList" \
  | grep -oE '"(componentCode|componentLibraryType|stockCount|componentModelEn)":"?[^",]*"?'
```

### When to fetch the LCSC product page directly

`https://www.lcsc.com/product-detail/C{N}.html` is **server-rendered** with full data. Use it when:
- the API's `erpComponentName` is too terse (you need parametric specs: ESR, temperature coefficient, AEC-Q status)
- you need the package drawing or footprint diagram
- you need to read the datasheet inline (`dataManualUrl` is the direct PDF link)

`www.lcsc.com/search?q=...` and `jlcpcb.com/parts` are JS-rendered SPAs — don't try to parse those HTML shells.

## Mode 2: Catalog lookup — `basic-parts.md`

`basic-parts.md` (in this skill's directory) is a markdown table of pre-resolved 0402 Basic Parts (resistors, ceramic caps, common semis). Read it once at the start of a session and quote codes inline — no API call per row.

```powershell
Get-JlcCatalog -Value '10K' -Package R0402   # one row, with staleness warning
Get-JlcCatalog -Value '10K' -Package R0402 -Quiet   # suppress the warning
```

For actual usage, prefer reading the .md file directly: it's 30-something rows and you'll want all of them in context anyway.

**Staleness warning.** `Get-JlcCatalog` parses the `Last refreshed: YYYY-MM-DD` line and warns when the catalog is more than 14 days old. Run `Update-JlcCatalog` to refresh.

**Refresh.** `Update-JlcCatalog` does the following on every run:
- Pulls every row's C-number through the API in parallel via runspace pool (default throttle 10 → ~15s for 35 rows; was 32s sequential)
- Detects **library drift** (Basic → Extended): warns
- Detects **MPN drift** (manufacturer renamed the part under the same C-number): warns
- Detects **low stock** (< 1000 units): warns
- Cross-checks the row's authored `Value` and `Package` against the API's MPN prefix and `erpComponentName` description via `Test-JlcRowMatch`: warns on mismatch
- Rewrites the file in place with current MPN, Library, Stock; updates the `Last refreshed:` timestamp

**Custom catalog location.** Set `$env:JLC_CATALOG_PATH` before loading the helper to use a different `basic-parts.md` location (e.g., a project-local catalog).

The catalog is keyed by C-number (stable). Adding a row: insert `| Cxxxxx | <value> | <package> | | | | <notes> |` and re-run `Update-JlcCatalog` — it fills in the dynamic columns.

## Mode 3: Parametric search via subagent

When the user asks for a component by criteria rather than name, spawn a `general-purpose` Agent with the template below. The subagent does the iterative search/narrow/datasheet-check loop and returns a recommendation, eating the API noise so it doesn't pollute this conversation.

**When to spawn:**
- "find me an ESD diode with 6V breakdown, 0805 or smaller, in-stock"
- "I need a 5V buck regulator at 1A, in SOT-23-6"
- "what's the cheapest 1uH 0805 inductor with ≥3A saturation current?"
- any "find me X with specs Y" where I'd need to iterate

**When NOT to spawn (just use Mode 1/2):**
- "verify C12345"
- "what's the LCSC code for ESP32-C6FH4"
- "is this part still in stock"
- single passive value already in catalog

### Subagent prompt template

```
You have access to JLCPCB's component-search JSON API for parametric sourcing.
No auth required.

Endpoint:
  POST https://jlcpcb.com/api/overseas-pcb-order/v1/shoppingCart/smtGood/selectSmtComponentList
  Content-Type: application/json
  Body: {"keyword":"<query>","currentPage":1,"pageSize":20,"componentLibraryType":""}

componentLibraryType: "" = all, "base" = JLCPCB Basic Parts only (no $3 setup fee).

Response: data.componentPageInfo.list[] of {componentCode, componentLibraryType,
stockCount, componentBrandEn, componentModelEn, erpComponentName, componentPrices,
preferredComponentFlag, leastPatchNumber, dataManualUrl}.

GOAL: <SPEC GOES HERE — what we're looking for>

CONSTRAINTS:
- Package: <e.g., 0805 or smaller>
- Spec: <e.g., 6V breakdown, ≥1A peak>
- Prefer: JLCPCB Basic over Extended; in stock (>1000 units); low cost
- Avoid: parts with leastPatchNumber > 50 unless nothing else qualifies

WORKFLOW:
1. Build a keyword query from the spec. For parametric searches, try
   manufacturer MPN families (e.g., for ESD diodes: PESD, SMF, ESDA series).
2. Run the search via curl. Sort results by Basic-first then stock.
3. For each promising candidate, fetch the LCSC product detail page at
   https://www.lcsc.com/product-detail/{componentCode}.html (use a real
   browser User-Agent like Mozilla/5.0 - it returns full SSR HTML).
   Verify the parametric spec from the page or from the dataManualUrl PDF.
4. Reject candidates that don't meet the constraints. Iterate with new
   keywords if needed (try 2-3 search variations).
5. Return EXACTLY this JSON, nothing else:

{
  "picked": {
    "code": "C12345",
    "mpn": "...",
    "brand": "...",
    "library": "base|expand",
    "stock": 12345,
    "price_at_100": 0.012,
    "datasheet": "https://...",
    "why": "one-sentence justification tied to the spec"
  },
  "alternates": [
    {"code": "...", "mpn": "...", "library": "...", "why": "..."}
  ],
  "rejected_examples": ["MPN — reason rejected", ...]
}

Keep your search to ≤6 API calls. If nothing qualifies, return picked: null
and explain why in alternates[0].why.
```

When invoking, fill `<SPEC GOES HERE>` and `CONSTRAINTS` with the user's actual ask. Pass via `Agent` tool with `subagent_type: "general-purpose"`.

## Common gotchas

- **MPN search can return a different SKU.** Samsung's `CL21A106KAYNNNE` exists as both C15850 (Basic) and C5137488 (Extended); MPN-keyword search returns the Extended one. When you have a known-Basic C-number, look it up by code, not by MPN.
- **`componentLibraryType:"base"` filter on parametric strings is unreliable.** Searching `"10K 0402"` with `base` filter returns whatever Basic Part is most popular overall (often a 100nF cap). Always use specific MPNs or the catalog for passives.
- **Two SKUs for one MPN** is common for popular ICs. ESP32-C6FH4 returns both `C6908287` (Espressif's official LCSC code) and `C9900274507` (JLCPCB-internal SKU) — both are Extended, both 0 stock. Pick the lower-numbered code unless the higher one has stock.
- **`erpComponentName` is often Chinese.** `厚膜电阻` = thick-film resistor, `贴片` = SMD. Don't filter on this field; use `componentTypeEn` or the MPN structure.
- **Stock numbers are JLCPCB-side, not LCSC-side.** A part can be 0 stock on JLCPCB but in stock at LCSC if you're buying loose; for assembly it's the JLCPCB number that gates ordering.
- **PS 5.1 mojibake.** Windows PowerShell 5.1's `Invoke-RestMethod` decodes responses as ISO-8859-1 by default, mangling JLCPCB's UTF-8 Chinese / Ω text. The helper works around this with `[System.Net.WebClient]` + explicit UTF-8 encoding. If you call the API from your own code on PS 5.1, do the same — otherwise `erpComponentName` comes back as `10kÎ©` instead of `10kΩ` and substring matching fails.
- **Em-dashes in helper.ps1 comments break PS 5.1 parsing** when loaded via `Invoke-Expression` (charset detection issue). The helper uses ASCII hyphens throughout. If you fork it, keep comments ASCII or load with explicit UTF-8: `Invoke-Expression ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))`.

## Footprint vocabulary (JLCPCB CSV upload)

When emitting a JLCPCB-format BOM CSV, use these footprint strings (not KiCad's):

`R0402` `R0603` `R0805` `R1206` · `C0402` `C0603` `C0805` `C1206` · `L0402` `L0603` · `LED0603` `LED0805` · `SOT-23` `SOT-23-5` `SOT-23-6` `SOT-89` `SOT-223` · `SOIC-8` `SOIC-14` `SSOP-14` `TSSOP-16` · `QFN-32-EP(5x5)` `QFN-48-EP(7x7)` etc.

If unsure, copy the package field from the API response or LCSC product page verbatim.

## Workflow: schematic → BOM (one application)

When the user gives you a schematic and asks for a JLCPCB BOM:

1. **Inventory.** Read every component: refdes, value, package, function. Group identical parts. Note DNP.
2. **Confirm with user** which MPNs are vendor-confirmed vs guessed-from-silkscreen.
3. **Resolve.** For each unique part:
   - In catalog (`basic-parts.md`)? Use that code.
   - Known MPN/C-number? `Search-Jlc -Keyword '<MPN>'` (Mode 1).
   - Spec-only ("6V ESD diode 0805")? Spawn a Mode 3 subagent.
4. **Flag risk.** Mark Extended parts (cost $3 each), low-stock parts (<1000), and any guessed packages.
5. **Emit CSV** with columns `Comment,Designator,Footprint,LCSC Part #`. Group designators by unique LCSC code, sort by refdes prefix.
6. **Summarize.** Total unique, Basic vs Extended count, setup cost = $3 × Extended-count, items the user should personally verify.

## When the user has a KiCad project

Prefer `.kicad_sch` over a PDF — use `kicad-cli sch export bom` if available, or parse `(symbol ... (property "Reference" ...) (property "Value" ...))` blocks. Then run each `Value` through the workflow above.
