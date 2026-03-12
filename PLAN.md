# Plan: New Tools

Three new tools to bring girvent to feature-complete for a coding agent.

## 1. edit_file — done

`edit_file(path, old_string, new_string)` — replace a unique substring in a file. Confirmation prompt shows red/green diff. Implemented in `tools.nim` and `girvent.nim`.

## 2. grep — done

`grep(pattern, path?, glob?)` — regex search via `rg --vimgrep`. Requires `rg` in PATH. Uses temp files to avoid pipe deadlock, `--max-count` per-file limit, stderr capture, 30s timeout. No confirmation (read-only). Implemented in `tools.nim` and `girvent.nim`.

## 3. lsp

Language-aware operations (find references, rename symbol, go to definition, diagnostics) via LSP. Textual search breaks down for renames in languages with overloads, qualified references, and complex scoping.

Minimal LSP client in Nim speaking JSON-RPC over stdio to any standard language server binary.

### Operations

| Operation | LSP Method | Agent use case |
|-----------|-----------|----------------|
| **references** | `textDocument/references` | Find all usages of a symbol before renaming/deleting |
| **definition** | `textDocument/definition` | Navigate to where something is defined |
| **rename** | `textDocument/rename` | Safe cross-file symbol rename with workspace edits |
| **diagnostics** | (push from server) | Check for errors after edits |

Not implementing: completions, hover, formatting, code actions, signature help.

### Architecture

```
src/lsp.nim         — LSP client: JSON-RPC stdio transport, request/response handling
```

**JSON-RPC transport**:
- LSP uses `Content-Length: N\r\n\r\n{json}` framing over stdin/stdout
- Maintain a request ID counter
- Send a request, read until we get a response with matching ID (buffer notifications)

**Lifecycle**:
- Lazy-start the language server on first `lsp` tool call
- Send `initialize` + `initialized` on startup
- Keep the server process alive across tool calls within a session
- On agent exit: send `shutdown` request, wait for response, send `exit` notification, terminate process
- Track the server PID so it can be killed if it doesn't exit gracefully

**Language server config**:
- User specifies the language server command in `AGENTS.md` or a config, e.g.:
  ```
  LSP: typescript-language-server --stdio
  LSP: kotlin-language-server
  LSP: nimlangserver
  ```
- Or auto-detect from project files (tsconfig.json → typescript-language-server, build.gradle.kts → kotlin-language-server, etc.)
- Start simple: one `AGENTS.md` directive, auto-detect later

**Tool schema**:
```
lsp(operation, file, line, column, new_name?)
```

**Response format**: Return structured text the model can act on:
- **references**: list of `file:line:col` locations
- **definition**: `file:line:col`
- **rename**: apply the workspace edit directly (with user confirmation showing all affected files), return summary
- **diagnostics**: list of `file:line: severity: message`

### Rename confirmation UX

1. Send `textDocument/rename` to get a `WorkspaceEdit`
2. Show the user a summary: which files change, how many locations
3. On confirmation, apply all edits
4. Return summary to the model

### Implementation order

1. JSON-RPC transport + initialize handshake
2. `definition` + `references` (read-only, safe to test)
3. `rename` (mutating, needs confirmation UX)
4. `diagnostics` (passive, collect from server notifications)
