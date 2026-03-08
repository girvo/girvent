# TODO

- [x] Stateful memory (ie. a `seq[]` of previous messages to add to them)

Maintain a seq of message objects that grows over the conversation. Each time you call the API, send the full history. Append the assistant's response to the history after each completion.

- [x] Tool definitions and response parsing

Define a small set of tools in the OpenAI function-calling schema and include them in your API request. Start with just two: `read_file(path)` and `list_directory(path)`. Don't execute them yet — just parse the response to detect when the model returns a tool_calls array instead of (or alongside) regular content. Print out what tool the model wants to call and with what arguments.

- [x] Agent loop

Implement the actual tool execution cycle:

1. Send messages to the API (with tool definitions)
2. If the response contains tool_calls, execute the corresponding function locally (actually read the file, actually list the directory)
3. Append the assistant's tool-call message to history
4. Append a tool role message with the result for each call
5. Call the API again with the updated history
6. Repeat until the model responds with plain text (no more tool calls)

- [x] Expand toolset

`write_file(path, content)` and `exec_bash(cmd)` implemented. Both require explicit user confirmation before executing. `exec_bash` runs through bash (located via `findExe`) and truncates output at 200 lines.

- [x] User Confirmation & Output Formatting

Confirmation prompts before write_file and exec_bash with Y/n (default yes), Enter to accept, Escape or n to reject. Terminal formatting with dim/styled tool call display, content preview (truncated at 16 lines), and markdown→ANSI rendering for model responses.

- [ ] System Prompt Engineering

Iterate on the system prompt. Tell the model what tools it has, how to use them, when to read files before editing, to think step-by-step, to verify its work by reading files after writing them.

- [ ] Optional Extensions
    - [ ] Streaming — switch from waiting for the full response to streaming tokens as they arrive (SSE parsing)
    - [ ] Context management — summarize or truncate history when you approach token limits; currently the `length` finish reason just prints and continues
    - [ ] Parallel tool calls — scatter-gather multiple tool calls in a single response instead of executing them serially
    - [ ] Multi-file edits — teach the model to use diff/patch style edits instead of rewriting whole files
    - [ ] Search tool — add `search_files(pattern)` using rg or similar
