# AGENTS.md Support Plan

## Goal

Load an optional `AGENTS.md` file and append its contents to the system prompt, giving the agent knowledge of CLI tools available on the system (e.g. `ddgr` for web search, `jq`, `curl`, etc.) that it can use via `exec_bash`.

## Design Decisions

- **Additive, not replacing** — existing tools (`read_file`, `write_file`, `list_directory`, `exec_bash`) stay as-is
- **File location** — look for `AGENTS.md` in the current working directory (same convention as CLAUDE.md). This keeps it project-local and versionable.
- **Optional** — if no `AGENTS.md` exists, the agent works exactly as it does today
- **Runtime, not compile-time** — read at startup so the system prompt reflects whatever's in the file when `girvent` is launched

## Implementation

### 1. Read AGENTS.md at startup (`src/girvent.nim`)

After constructing the base system prompt and before adding it to `messages`:

```
- Try to read `AGENTS.md` from getCurrentDir()
- If it exists, append its contents to the system prompt string with a clear section header
- If it doesn't exist, use the system prompt as-is
```

The appended section should be wrapped like:

```
AGENTS.md:
<contents of AGENTS.md>
```

This keeps it clearly delineated from the base prompt.

### 2. Changes required

**`src/girvent.nim`** — the only file that needs changes:

- Change `systemPrompt` from a `let` to be constructed in two steps:
  1. Build the base prompt string (current content)
  2. Try reading `AGENTS.md` — if found, concatenate it
  3. Pass the final string to `initMessage(Role.system, ...)`
- Add `AGENTS.md` path to the startup display so the user knows it was loaded (e.g. a subtle line under the model name)

No changes needed to `tools.nim`, `openai.nim`, or `md_ansi.nim`.

### 3. Example AGENTS.md

Ship an example file (or just document the format in README.md) showing the intended usage:

```markdown
## CLI Tools

The following CLI tools are available on this system. Use them via `exec_bash` when relevant.

### Web Search — ddgr
Search the web from the terminal using DuckDuckGo.
- `ddgr "search query"` — search and display results
- `ddgr -n 5 "query"` — limit to 5 results
- `ddgr --json "query"` — output as JSON (pipe to jq for processing)

### JSON Processing — jq
- `echo '{"key": "value"}' | jq '.key'` — extract fields
- `cat file.json | jq '.items[] | .name'` — iterate arrays

### HTTP — curl
- `curl -s https://api.example.com/data` — GET request
- `curl -s url | jq '.'` — fetch and parse JSON
```

### 4. README update

Add a section to README.md documenting AGENTS.md support:
- What it is
- Where to put it
- Example content

## Scope

- ~20 lines of Nim code changed in `girvent.nim`
- No new dependencies
- No changes to tool definitions or the OpenAI types
- Backwards compatible — no AGENTS.md means no change in behavior
