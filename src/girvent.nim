import std/os
import std/httpclient
import std/options
import std/json
import std/strutils
import std/terminal
import dotenv
import jsony
import noise
import ./openai
import ./tools
import ./md_ansi

var apiKey = getEnv("GIRVENT_API_KEY", "")
if apiKey == "":
  load() # load .env file
  apiKey = getEnv("GIRVENT_API_KEY", "")
if apiKey == "":
  raise newException(OSError, "Must set API_KEY in .env file or environment")

type
  Model = object
    id: string
    contextWindow: int

const
  Qwen_3_5 = Model(id: "qwen3.5-plus",  contextWindow: 1_000_000)
  GLM_5    = Model(id: "glm-5",           contextWindow: 200_000)
  KimiK_2_5  = Model(id: "kimi-k2.5",      contextWindow: 256_000)
  MiniMaxM_2_5 = Model(id: "MiniMax-M2.5",  contextWindow: 205_000)
  AllModels = [Qwen_3_5, GLM_5, KimiK_2_5, MiniMaxM_2_5]

let apiUrl = "https://coding-intl.dashscope.aliyuncs.com/v1/chat/completions"

# Build system prompt
var systemPromptContent = """
You are an expert software engineering assistant.

Working directory: """ & getCurrentDir() & """

ROLE:
- Help users write, debug, and improve code
- Follow best practices for each language/framework
- Prioritize correctness and safety over speed

WORKFLOW:
- Understand the task fully before acting
- Read existing files to understand context before modifying them
- Plan your approach, then execute step-by-step
- Verify each change before proceeding
- Test when possible before declaring completion

TOOLS:
- read_file(path): Read a file's contents. Always read before writing.
- write_file(path, content): Write a file. Never overwrite without reading first. Prefer edit_file for modifications.
- edit_file(path, old_string, new_string): Replace a substring in a file. The old_string must match exactly once. Prefer this over write_file for modifying existing files — include enough surrounding context in old_string to ensure a unique match.
- list_directory(path): List directory contents. Use to explore project structure. [f] means file, [d] means directory, dont list_directory on files
- grep(pattern, path?, glob?): Search file contents with regex using ripgrep. Returns file:line:col:match format. Limited to 500 results. Use to find symbols, patterns, or text across the codebase.
- exec_bash(cmd, timeout?): Run a shell command. Use for building, testing, and tasks that read_file/write_file can't handle.
  - Commands time out after 120s by default. Pass timeout=0 for long-running commands (builds, installs), or a custom value in seconds.
  - Prefer read-only and reversible operations; confirm with the user before executing anything destructive
  - Use dry-run flags when available
  - Check exit codes and output after each command
  - Use /tmp for intermediate/scratch files

ERRORS:
- If a tool returns an error, report it to the user and explain what went wrong
- Do not silently retry the same failing operation
- Ask the user for guidance if you cannot resolve the error yourself

FILE SYSTEM SAFETY:
- Use /tmp or mktemp for temporary/intermediate files
- Clean up temporary files when no longer needed

CODE QUALITY:
- Match the existing style and conventions of the codebase
- Keep changes minimal and focused on what was asked
- Do not add documentation, error handling, or refactoring beyond the scope of the task

SECURITY:
- Never expose API keys, passwords, or tokens
- Warn if you detect hardcoded secrets
- Use environment variables for configuration

COMMUNICATION:
- Explain your reasoning for non-obvious decisions
- Ask clarifying questions when requirements are ambiguous
- Warn before making breaking changes
- Be honest about limitations and uncertainties
- For multi-step tasks, summarize what was accomplished at the end
"""

# Try to read AGENTS.md and append if it exists
let agentsMdPath = "AGENTS.md"
if fileExists(agentsMdPath):
  systemPromptContent.add("\n\nAGENTS.md:\n")
  systemPromptContent.add(readFile(agentsMdPath))

let systemPrompt = initMessage(Role.system, systemPromptContent)

var
  model = Qwen_3_5
  messages = newSeq[Message]()
  lastUsage: Option[Usage]
  client = newHttpClient()
client.headers = newHttpHeaders({
  "Accept": "application/json",
  "Content-Type": "application/json",
  "Authorization": "Bearer " & apiKey
})

type
  SlashCommand = enum
    scClear, scContext, scHelp, scModel, scQuit

proc `$`(cmd: SlashCommand): string =
  case cmd
  of scClear:   "/clear"
  of scContext:  "/context"
  of scHelp:    "/help"
  of scModel:   "/model"
  of scQuit:    "/quit"

proc cmdDescription(cmd: SlashCommand): string =
  case cmd
  of scClear:   "clear conversation history"
  of scContext:  "show context window usage"
  of scHelp:    "show this help"
  of scModel:   "show or switch model"
  of scQuit:    "exit"

proc parseSlashCommand(input: string): Option[SlashCommand] =
  for cmd in SlashCommand:
    if $cmd == input:
      return some(cmd)

proc slashCompletionHook(noise: var Noise, text: string): int =
  let line = noise.getLine()
  if line.len > 0 and line[0] == '/':
    if line.startsWith("/model "):
      for mdl in AllModels:
        if mdl.id.startsWith(text):
          noise.addCompletion(mdl.id)
    else:
      for cmd in SlashCommand:
        let cmdStr = $cmd
        if cmdStr.startsWith(text):
          noise.addCompletion(cmdStr)
  result = 0

proc printSeparator() =
  let width = terminalWidth()
  styledEcho(ansiForegroundColorCode(c256Gray), "─".repeat(width))

proc normalizePathForDisplay(path: string): string =
  ## Normalize a path for display: show relative if within CWD, absolute otherwise
  let
    cwd = getCurrentDir()
    absolutePath = if path.isAbsolute: path else: cwd / path
    normalizedAbsolute = absolutePath.absolutePath
    normalizedCwd = cwd.absolutePath

  if normalizedAbsolute == normalizedCwd:
    return "."
  elif normalizedAbsolute.startsWith(normalizedCwd & "/"):
    return normalizedAbsolute[normalizedCwd.len + 1 ..^ 1]
  else:
    return normalizedAbsolute

proc showToolCall(name: string, args: JsonNode) =
  stdout.write(ansiStyleCode(styleDim) & "[tool] " & ansiResetCode)
  stdout.write(ansiBackgroundColorCode(c256DarkGray) & " " & name & " " & ansiResetCode)
  if args.len > 0:
    stdout.write(ansiStyleCode(styleDim) & "  ")
    for key, val in args.pairs:
      if key == "path":
        let displayPath = normalizePathForDisplay(val.getStr())
        stdout.write(key & "=" & displayPath & " ")
      else:
        stdout.write(key & "=" & val.getStr(val.pretty) & " ")
    stdout.write(ansiResetCode)
  stdout.write("\n")
  stdout.flushFile()

proc showContext() =
  let
    contextLimit = model.contextWindow
    barWidth = 30
  if lastUsage.isNone():
    echo ""
    styledEcho("  No context data yet.")
    echo ""
    return
  let
    usage = lastUsage.get()
    prompt = insertSep($usage.promptTokens, ',')
    completion = insertSep($usage.completionTokens, ',')
    total = insertSep($usage.totalTokens, ',')
    limit = insertSep($contextLimit, ',')
    colWidth = max(prompt.len, max(completion.len, max(total.len, limit.len)))
    filled = barWidth * usage.totalTokens div contextLimit
    bar = "█".repeat(filled) & "░".repeat(barWidth - filled)
    pct = usage.totalTokens * 100 div contextLimit
  echo ""
  styledEcho("  ", styleBright, "context")
  echo ""
  styledEcho("  ", fgCyan, "prompt      ", resetStyle, prompt.align(colWidth), ansiForegroundColorCode(c256Gray), " tokens")
  styledEcho("  ", fgYellow, "completion  ", resetStyle, completion.align(colWidth), ansiForegroundColorCode(c256Gray), " tokens")
  styledEcho("  ", ansiForegroundColorCode(c256Gray), "            " & "─".repeat(colWidth + 7))
  styledEcho("  ", styleBright, "total       ", resetStyle, total.align(colWidth), ansiForegroundColorCode(c256Gray), " tokens")
  styledEcho("  ", ansiForegroundColorCode(c256Gray), "limit       ", resetStyle, limit.align(colWidth), ansiForegroundColorCode(c256Gray), " tokens")
  echo ""
  styledEcho("  ", fgCyan, bar, resetStyle, "  ", $pct & "%")
  echo ""

proc showModels() =
  echo ""
  styledEcho("  ", styleBright, "models")
  echo ""
  for mdl in AllModels:
    if mdl.id == model.id:
      styledEcho("  ", fgCyan, styleBright, "● ", resetStyle, styleBright, mdl.id)
    else:
      styledEcho("    ", mdl.id)
  echo ""

proc showHelp() =
  echo ""
  styledEcho("  ", styleBright, "commands", ansiForegroundColorCode(c256Gray), "  ·  ", ansiForegroundColorCode(c256DimGray), "Tab completes slash commands")
  echo ""
  for cmd in SlashCommand:
    styledEcho("  ", fgCyan, ($cmd).alignLeft(11), resetStyle, cmdDescription(cmd))
  echo ""

proc sendReq(): ChatResponse =
  var rawBody = ""
  try:
    let
      body = initRequestBody(model.id, messages, some(tools.allTools))
      response = client.request(apiUrl, httpMethod = HttpPost, body = body.toJson())
    rawBody = response.body
    if response.status != "200 OK":
      let error = rawBody.fromJson(ChatErrorResponse)
      return ChatResponse(kind: err, error: error)
    else:
      let parsed = rawBody.fromJson(ChatCompletionResponse)
      return ChatResponse(kind: ok, response: parsed)
  except:
    let error = initCustomError(getCurrentExceptionMsg() & "\nRaw body: " & rawBody)
    return ChatResponse(kind: err, error: error)

proc handleToolCalls(choice: var Choice): bool =
  ## This is the inner tool call loop
  ## Returns true if the conversation should continue, false if an error occurred
  var iterationCount = 0

  while true:
    inc iterationCount
    if iterationCount >= 30:
      styledEcho(fgRed, "Loop error: too many iterations " & $iterationCount)
      return false

    # Print any content from the assistant message
    if choice.message.content.isSome() and choice.message.content.get().strip().len > 0:
      echo ""
      echo choice.message.content.get().renderMarkdown()
      echo ""

    # Execute each tool call
    for toolCall in choice.message.toolCalls.get():
      let args = parseJson(toolCall.function.arguments)

      case toolCall.function.name
      of ToolName.readFile:
        showToolCall($toolCall.function.name, args)
        try:
          let fileContents = callReadFile(args["path"].getStr())
          messages.add(initToolCallMessage(toolCall.id, fileContents))
        except IOError:
          messages.add(initToolCallMessage(toolCall.id, "ERROR! Could not read file: " & getCurrentExceptionMsg()))
      of ToolName.listDirectory:
        showToolCall($toolCall.function.name, args)
        let folderContents = callListDirectory(args["path"].getStr())
        messages.add(initToolCallMessage(toolCall.id, folderContents))
      of ToolName.writeFile:
        let
          path = args["path"].getStr()
          content = args["content"].getStr()
        showToolCall($toolCall.function.name, %*{"path": path})
        if promptWriteFile(path, content):
          messages.add(initToolCallMessage(toolCall.id, callWriteFile(path, content)))
        else:
          messages.add(initToolCallMessage(toolCall.id, "user explicitly rejected write"))
      of ToolName.editFile:
        let
          path = args["path"].getStr()
          oldString = args["old_string"].getStr()
          newString = args["new_string"].getStr()
        showToolCall($toolCall.function.name, %*{"path": path})
        if promptEditFile(path, oldString, newString):
          messages.add(initToolCallMessage(toolCall.id, callEditFile(path, oldString, newString)))
        else:
          messages.add(initToolCallMessage(toolCall.id, "user explicitly rejected edit"))
      of ToolName.grep:
        let
          pattern = args["pattern"].getStr()
          path = if args.hasKey("path"): args["path"].getStr() else: "."
          glob = if args.hasKey("glob"): args["glob"].getStr() else: ""
        showToolCall($toolCall.function.name, %*{"pattern": pattern, "path": path})
        messages.add(initToolCallMessage(toolCall.id, callGrep(pattern, path, glob)))
      of ToolName.execBash:
        let
          cmd = args["cmd"].getStr()
          timeout = if args.hasKey("timeout"): args["timeout"].getInt() else: 120
        showToolCall($toolCall.function.name, newJObject())
        if promptExecBash(cmd):
          messages.add(initToolCallMessage(toolCall.id, callExecBash(cmd, timeout)))
        else:
          messages.add(initToolCallMessage(toolCall.id, "user explicitly rejected execution"))
      else:
        styledEcho(fgYellow, "Unimplemented tool call detected")
        messages.add(initToolCallMessage(toolCall.id, "tool is not implemented yet, try bash?"))

    # Send follow-up request after tool results
    let res = sendReq()
    if res.kind == err:
      styledEcho(fgRed, "Error returned: ")
      echo res.error.error.message
      return false

    choice = res.response.choices[0]
    lastUsage = some(res.response.usage)
    messages.add(choice.message)

    # Check finish reason to determine next action
    case choice.finishReason
    of stop:
      printSeparator()
      echo choice.message.content.get().renderMarkdown() & "\n"
      return true
    of toolCalls:
      continue
    else:
      echo "Unexpected finish reason: " & $choice.finishReason
      return true

proc runAgent() =
  var noise = Noise.init()
  let prompt = Styler.init(fgGreen, "> ")
  noise.setPrompt(prompt)
  noise.setCompletionHook(slashCompletionHook)

  messages.add(systemPrompt)

  echo ""
  styledEcho("  ", styleBright, "Coding Agent", resetStyle, ansiForegroundColorCode(c256Gray), "  ·  ", resetStyle, model.id)
  if fileExists(agentsMdPath):
    styledEcho(ansiForegroundColorCode(c256DimGray), "  AGENTS.md loaded")
  echo ""
  styledEcho(ansiForegroundColorCode(c256Gray), "  Type your prompt to get started. Type /help for available commands.")
  echo ""

  while true:
    let read = noise.readLine()
    if not read: break

    let input = noise.getLine()

    if input == "/model" or input.startsWith("/model "):
      let arg = if input.len > 7: input[7..^1].strip() else: ""
      if arg == "":
        showModels()
      else:
        var found = false
        for mdl in AllModels:
          if mdl.id == arg:
            model = mdl
            found = true
            echo ""
            styledEcho("  ", fgGreen, "Switched to ", styleBright, mdl.id)
            echo ""
            break
        if not found:
          echo ""
          styledEcho("  ", fgRed, "Unknown model: ", resetStyle, arg)
          echo ""
      continue

    let slashCmd = parseSlashCommand(input)
    if slashCmd.isSome:
      case slashCmd.get()
      of scClear:
        stdout.eraseScreen()
        stdout.setCursorPos(0, 0)
        messages.reset()
        messages.add(systemPrompt)
      of scContext:
        showContext()
      of scHelp:
        showHelp()
      of scModel:
        showModels()
      of scQuit:
        echo "Goodbye"
        break
    else:
      messages.add(initMessage(Role.user, input))
      styledEcho("\n", ansiForegroundColorCode(c256Gray), "Thinking...\n")
      let
        currentLen = messages.len
        res = sendReq()
      case res.kind
      of ok:
        var choice = res.response.choices[0]
        lastUsage = some(res.response.usage)
        messages.add(choice.message)

        case choice.finishReason
        of stop:
          printSeparator()
          echo choice.message.content.get().renderMarkdown() & "\n"
        of contentFilter:
          echo "Hit a content filter, oop"
          discard messages.pop()
        of length:
          echo "Hit length condition, printing anyway:"
          echo choice.message.content.get().renderMarkdown()
        of toolCalls:
          if not handleToolCalls(choice):
            messages.setLen(currentLen)
      of err:
        messages.setLen(currentLen)
        styledEcho(fgRed, "Error returned: ")
        echo res.error.error.message

when isMainModule:
  runAgent()
