# Plan: New Tools

Three new tools to bring girvent to feature-complete for a coding agent.

## 1. edit_file

**Purpose**: Replace a unique substring in a file without rewriting the entire file. Saves tokens on every edit.

**Tool schema**:
```
edit_file(path, old_string, new_string)
```

**Behavior**:
- Read the file into memory (`readFile`)
- Find `old_string` — must match exactly once. Error on 0 or 2+ matches.
- Replace with `new_string` and write the file back
- User confirmation prompt (like `write_file`): show a before/after diff of the change

**Implementation**: Pure `strutils` — `find` to locate, `count` to verify uniqueness, string concat to replace. No external deps.

**System prompt addition**: Tell the model to prefer `edit_file` over `write_file` for modifying existing files, and to include enough surrounding context in `old_string` to ensure a unique match.

## 2. grep

**Purpose**: Regex search across files. The model currently has to `exec_bash` with grep/rg, which works but is undiscoverable and the model often forgets it can do this.

**Tool schema**:
```
grep(pattern, path?, glob?)
```
- `pattern`: regex pattern (passed to `rg`)
- `path`: directory to search in (default: working directory)
- `glob`: file filter, e.g. `"*.nim"` (optional)

**Behavior**:
- Shell out to `rg` with `--json` or `--vimgrep` for structured output
- Truncate results (reuse existing `maxOutputLines` constant)
- No confirmation needed (read-only operation)

**Prerequisite**: `rg` must be in PATH. Error clearly if not found (like we do for `bash`).

## 3. lsp

**Purpose**: Language-aware operations (find references, rename symbol, go to definition, diagnostics) via LSP. Textual search breaks down for renames in languages with overloads, qualified references, and complex scoping (Kotlin, Java, C#, etc).

**Approach**: Implement a minimal LSP client in Nim that speaks JSON-RPC over stdio to any standard language server binary.

### LSP operations to support

Only what a coding agent actually needs:

| Operation | LSP Method | Agent use case |
|-----------|-----------|----------------|
| **references** | `textDocument/references` | Find all usages of a symbol before renaming/deleting |
| **definition** | `textDocument/definition` | Navigate to where something is defined |
| **rename** | `textDocument/rename` | Safe cross-file symbol rename with workspace edits |
| **diagnostics** | (push from server) | Check for errors after edits |

Not implementing: completions, hover, formatting, code actions, signature help — the model doesn't need IDE comfort features.

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
- `operation`: one of `references`, `definition`, `rename`, `diagnostics`
- `file`: path to the file containing the symbol
- `line`: 0-based line number
- `column`: 0-based character offset
- `new_name`: required for `rename` only

**Response format**: Return structured text the model can act on:
- **references**: list of `file:line:col` locations
- **definition**: `file:line:col`
- **rename**: apply the workspace edit directly (with user confirmation showing all affected files), return summary
- **diagnostics**: list of `file:line: severity: message`

### Rename confirmation UX

Rename is the most impactful operation. On `rename`:
1. Send `textDocument/rename` to get a `WorkspaceEdit`
2. Show the user a summary: which files change, how many locations
3. On confirmation, apply all edits
4. Return summary to the model

## Implementation order

1. **edit_file** — smallest, highest immediate value, no external deps
2. **grep** — small, depends only on `rg` existing
3. **lsp** — largest, implement incrementally:
   a. JSON-RPC transport + initialize handshake
   b. `definition` + `references` (read-only, safe to test)
   c. `rename` (mutating, needs confirmation UX)
   d. `diagnostics` (passive, collect from server notifications)

## System prompt changes

Add to the tool descriptions in the system prompt:

```
- edit_file(path, old_string, new_string): Replace a substring in a file. The old_string must match exactly once. Prefer this over write_file for modifications.
- grep(pattern, path?, glob?): Search file contents with regex. Use to find symbols, patterns, or text across the codebase.
- lsp(operation, file, line, column, new_name?): Language-aware operations via LSP. Use for finding references, going to definitions, and renaming symbols safely across files. Available operations: references, definition, rename.
```
