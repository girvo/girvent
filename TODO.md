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

- [ ] Expand toolset

Add the tools that make it a coding agent: `write_file(path, content)`, `run_command(command)` (with a subprocess call), and maybe `search_files(pattern)` using rg or similar.

- [ ] User Confirmation & Output Formatting

Add a confirmation prompt before executing destructive tools (write_file, run_command). Add some basic terminal formatting — maybe color the model's text differently from tool output, show a spinner while waiting, display tool calls in a structured way rather than raw JSON.

- [ ] System Prompt Engineering

Iterate on your system prompt. Tell the model what tools it has, how to use them, when to read files before editing, to think step-by-step, to verify its work by reading files after writing them. This is where you'll spend surprisingly large amounts of time.

- [ ] Optional Extensions
    - [ ] Streaming — switch from waiting for the full response to streaming tokens as they arrive (SSE parsing)
    - [ ] Context management — summarize or truncate history when you approach token limits
    - [ ] Multi-file edits — teach the model to use diff/patch style edits instead of rewriting whole files
    - [ ] Error recovery — if a command fails, feed the error back and let the model retry
