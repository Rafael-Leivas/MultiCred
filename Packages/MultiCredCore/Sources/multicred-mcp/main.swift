import Foundation
import MultiCredHelp

// A client that disappears must not kill us with SIGPIPE mid-write.
signal(SIGPIPE, SIG_IGN)

// Help MCP server for MultiCred (stdio). Read-only: see docs/SECURITY.md.
let guide = Guide.bundled
let server = MCPServer.help(guide: guide, diagnostics: MCPRuntime.makeDiagnosticService(guide: guide))
await server.serve()
