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

let
  systemPrompt = initMessage(Role.system, """
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
- write_file(path, content): Write a file. Never overwrite without reading first.
- list_directory(path): List directory contents. Use to explore project structure.
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
""")

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
      # text is just the current word (model name partial)
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
  styledEcho(fgBlack, styleBright, "─".repeat(width))

proc showToolCall(name: string, args: JsonNode) =
  stdout.write(ansiStyleCode(styleDim) & "[tool] " & ansiResetCode)
  stdout.write(ansiBackgroundColorCode(c256DarkGray) & " " & name & " " & ansiResetCode)
  if args.len > 0:
    stdout.write(ansiStyleCode(styleDim) & "  ")
    for key, val in args.pairs:
      stdout.write(key & "=" & val.getStr(val.pretty) & " ")
    stdout.write(ansiResetCode)
  stdout.write("\n")
  stdout.flushFile()

proc showContext() =
  let contextLimit = model.contextWindow
  const barWidth = 30
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
  styledEcho("  ", fgCyan, "prompt      ", resetStyle, prompt.align(colWidth), fgBlack, styleBright, " tokens")
  styledEcho("  ", fgYellow, "completion  ", resetStyle, completion.align(colWidth), fgBlack, styleBright, " tokens")
  styledEcho("  ", fgBlack, styleBright, "            " & "─".repeat(colWidth + 7))
  styledEcho("  ", styleBright, "total       ", resetStyle, total.align(colWidth), fgBlack, styleBright, " tokens")
  styledEcho("  ", fgBlack, styleBright, "limit       ", resetStyle, limit.align(colWidth), fgBlack, styleBright, " tokens")
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
  styledEcho("  ", styleBright, "commands", fgBlack, styleBright, "  ·  ", resetStyle, fgBlack, styleDim, "Tab completes slash commands")
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

proc runAgent() =
  var noise = Noise.init()
  let prompt = Styler.init(fgGreen, "> ")
  noise.setPrompt(prompt)
  noise.setCompletionHook(slashCompletionHook)

  messages.add(systemPrompt)

  echo ""
  styledEcho("  ", styleBright, "Coding Agent", resetStyle, fgBlack, styleBright, "  ·  ", resetStyle, model.id)
  echo ""
  styledEcho(fgBlack, styleBright, "  Type your prompt to get started. Type ", "/help", fgBlack, styleBright, " for available commands.")
  echo ""

  while true:
    let read = noise.readLine()
    if not read: break

    let input = noise.getLine()

    # Handle /model with optional argument before generic slash parsing
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
      styledEcho("\n", fgBlack, "Thinking...\n")
      let
        currentLen = messages.len
        res = sendReq()
      case res.kind
      of ok:
        # This is "safe" enough as we always get choices len 1 back
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
          # TODO: Probably compact instead, right?
        of toolCalls:
          # Inner tool calling loop time
          # TODO: Eventually this should scatter-gather parallel calls
          var iterationCount = 0
          while true:
            inc iterationCount
            if iterationCount >= 30:
              styledEcho(fgRed, "Loop error: too many iterations " & $iterationCount)
              messages.setLen(currentLen)
              break
            if choice.message.content.isSome() and choice.message.content.get().strip().len > 0:
              echo ""
              echo choice.message.content.get().renderMarkdown()
              echo ""
            for toolCall in choice.message.toolCalls.get():
              let args = parseJson(toolCall.function.arguments)

              case toolCall.function.name
              of ToolName.readFile:
                showToolCall($toolCall.function.name, args)
                try:
                  let fileContents = readFile(args["path"].getStr())
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
              of ToolName.execBash:
                let
                  cmd = args["cmd"].getStr()
                  timeout = if args.hasKey("timeout"): args["timeout"].getInt() else: 120
                showToolCall($toolCall.function.name, newJObject())
                if promptExecBash(cmd):
                  messages.add(initToolCallMessage(toolCall.id, callExecBash(cmd, timeout)))
                else:
                  messages.add(initToolCallMessage(toolCall.id, "user explicitly rejected execution"))
            let res = sendReq()
            if res.kind == err:
              # Drop messages that caused the error
              messages.setLen(currentLen)
              styledEcho(fgRed, "Error returned: ")
              echo res.error.error.message
              break
            else:
              choice = res.response.choices[0]
              lastUsage = some(res.response.usage)
              messages.add(choice.message)

              case choice.finishReason
              of stop:
                printSeparator()
                echo choice.message.content.get().renderMarkdown() & "\n"
                break # inner loop
              of toolCalls:
                continue
              else:
                echo "Unexpected finish reason: " & $choice.finishReason
                break
      of err:
        # Drop messages that caused the error
        messages.setLen(currentLen)
        styledEcho(fgRed, "Error returned: ")
        echo res.error.error.message

when isMainModule:
  runAgent()
