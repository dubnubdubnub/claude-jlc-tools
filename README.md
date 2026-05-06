# claude-jlc-tools

Claude Code plugins for JLCPCB / LCSC component sourcing and KiCad library workflows.

## Plugins

### `jlcpcb-catalog`

Query JLCPCB / LCSC's parts catalog directly via the public JSON API.

- Resolve MPNs to LCSC C-numbers (`Search-Jlc`, `Get-JlcByCode`)
- Check JLCPCB Basic-vs-Extended status and stock at the moment of asking
- 35-row offline catalog of canonical Basic Parts (resistors, ceramic caps, semis), refreshed in place by `Update-JlcCatalog` against the live API
- Parametric-search subagent template for "find me a 6V ESD diode in 0805 or smaller" style queries

PowerShell helpers; works on Windows PS 5.1+ (UTF-8 + TLS handled). Schema for the catalog is keyed by C-number and re-resolved on demand.

## Install

```
/plugin marketplace add dubnubdubnub/claude-jlc-tools
/plugin install jlcpcb-catalog@jlc-tools
```

To update later, after I push a new release:

```
/plugin marketplace update jlc-tools
```

then reinstall.

## Versioning

Plugin versions live in `plugins/<name>/.claude-plugin/plugin.json` (and the corresponding `marketplace.json` entry). Bump the `version` field on every release; users only see updates when that string changes.

## License

MIT
