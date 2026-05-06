# JLCPCB Basic Parts catalog

Single source of truth for the offline Basic Parts list. Keyed by LCSC
**C-number** (stable). The `MPN`, `Library`, and `Stock` columns are
refreshed from the live JLCPCB API by `Update-JlcCatalog`; the `Code`,
`Value`, `Package`, and `Notes` columns are authored.

To refresh in place (rewrites this file):

    Get-Content $HOME\.claude\skills\jlcpcb-catalog\helper.ps1 -Raw | Invoke-Expression
    Update-JlcCatalog

Add a row by inserting `| Cxxxxx | <value> | <package> | | | | <notes> |`
and re-running `Update-JlcCatalog` â€” it fills in the dynamic columns.

If a row's `Library` flips from `base` to `expand`, the refresher prints a
warning. Drift happens â€” JLCPCB re-tiers parts every few months.

Last refreshed: 2026-05-05

## Catalog

| Code | Value | Package | MPN | Library | Stock | Notes |
|---|---|---|---|---|---|---|
| C17168 | 0R | R0402 | 0402WGF0000TCE | base | 12.2M | jumper |
| C25077 | 10R | R0402 | 0402WGF100JTCE | base | 2.1M |  |
| C25092 | 22R | R0402 | 0402WGF220JTCE | base | 4.3M | USB D+/D- series |
| C25105 | 33R | R0402 | 0402WGF330JTCE | base | 5.1M |  |
| C25076 | 100R | R0402 | 0402WGF1000TCE | base | 3.5M |  |
| C25091 | 220R | R0402 | 0402WGF2200TCE | base | 6.8M |  |
| C25117 | 470R | R0402 | 0402WGF4700TCE | base | 2.3M |  |
| C11702 | 1K | R0402 | 0402WGF1001TCE | base | 12.3M |  |
| C25879 | 2.2K | R0402 | 0402WGF2201TCE | base | 2.0M |  |
| C25900 | 4.7K | R0402 | 0402WGF4701TCE | base | 5.4M |  |
| C25905 | 5.1K | R0402 | 0402WGF5101TCE | base | 8.4M | USB-C CC pull-down |
| C25744 | 10K | R0402 | 0402WGF1002TCE | base | 6.3M | general pull-up |
| C25768 | 22K | R0402 | 0402WGF2202TCE | base | 1.2M |  |
| C25792 | 47K | R0402 | 0402WGF4702TCE | base | 2.7M |  |
| C25741 | 100K | R0402 | 0402WGF1003TCE | base | 5.9M |  |
| C26083 | 1M | R0402 | 0402WGF1004TCE | base | 1.4M |  |
| C32949 | 10pF | C0402 | CL05C100JB5NNNC | base | 3.1M | NP0 50V |
| C1547 | 12pF | C0402 | 0402CG120J500NT | base | 1.8M | NP0 50V â€” crystal load cap |
| C1548 | 15pF | C0402 | 0402CG150J500NT | base | 1.5M | NP0 50V |
| C1549 | 18pF | C0402 | 0402CG180J500NT | base | 1.3M | NP0 50V |
| C1555 | 22pF | C0402 | 0402CG220J500NT | base | 2.4M | NP0 50V |
| C1567 | 47pF | C0402 | 0402CG470J500NT | base | 2.3M | NP0 50V |
| C1546 | 100pF | C0402 | 0402CG101J500NT | base | 5.3M | NP0 50V |
| C1523 | 1nF | C0402 | 0402B102K500NT | base | 3.0M | X7R 50V |
| C15195 | 10nF | C0402 | CL05B103KB5NNNC | base | 8.4M | X7R 50V (Samsung) |
| C307331 | 100nF | C0402 | CL05B104KB54PNC | base | 18.0M | X7R 50V â€” main decoupling |
| C1525 | 100nF/16V | C0402 | CL05B104KO5NNNC | base | 18.7M | X7R 16V â€” derate margin smaller |
| C52923 | 1uF | C0402 | CL05A105KA5NQNC | base | 8.4M | X5R 25V |
| C12530 | 2.2uF | C0402 | CL05A225MQ5NSNC | base | 3.9M | X5R 6.3V â€” note voltage derate |
| C15850 | 10uF | C0805 | CL21A106KAYNNNE | base | 3.9M | X5R 25V â€” no Basic 0402 10uF |
| C19702 | 10uF | C0603 | CL10A106KP8NNNC | base | 5.5M | X5R 10V â€” 0603 alternative |
| C45783 | 22uF | C0805 | CL21A226MAQNNNE | base | 3.4M | X5R 25V |
| C1779 | 4.7uF | C0805 | CL21A475KAQNNNE | base | 2.9M | X5R 25V |
| C2128 | 1N4148 | SOD-323 | 1N4148WS | base | 4.3M | signal diode |
| C2146 | S8050 | SOT-23 | S8050 J3Y(RANGE:200-350) | base | 1.8M | NPN signal |

## Things NOT catalogued (always Extended for these specs)

- 2.2uF 0402 X5R at 10V or higher â€” only 6.3V (C12530) is Basic
- RF caps: 0.1pF, 0.5pF, 0.75pF, 1pF, antenna-matching values
- Crystals at any frequency or package
- 0201, 01005, larger SMD, or non-standard tolerance (0.1%, AEC-Q200)
- 499R 0402 1% â€” closest Basic is 470R (C25117) or 510R (Extended)
- USB-C 16-pin connectors, microSD sockets, FPC connectors â€” vendor-specific, not in this offline list

For these, query the API directly (`Search-Jlc -Keyword '<MPN>'`) and accept Extended â€” or spawn a parametric-search subagent (see SKILL.md Mode 3).
