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

# We need to load the .env file first
load()

let
  apiUrl = "https://coding-intl.dashscope.aliyuncs.com/v1/chat/completions"
  apiKey = getEnv("API_KEY", "")
  modelId = "qwen3.5-plus"
  systemPrompt = initMessage(Role.system, "You are a coding agent, and an expert in programming")

if apiKey == "":
  raise newException(OSError, "Must set API_KEY in .env file")

var
  messages = newSeq[Message]()
  client = newHttpClient()
client.headers = newHttpHeaders({
  "Accept": "application/json",
  "Content-Type": "application/json",
  "Authorization": "Bearer " & apiKey
})

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

proc sendReq(): ChatResponse =
  var rawBody = ""
  try:
    let body = initRequestBody(modelId, messages, some(tools.allTools))
    let response = client.request(apiUrl, httpMethod = HttpPost, body = body.toJson())
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

  messages.add(systemPrompt)

  while true:
    let read = noise.readLine()
    if not read: break

    let input = noise.getLine()
    if input == "/quit":
      echo "Goodbye"
      break
    if input == "/clear":
      stdout.eraseScreen()
      stdout.setCursorPos(0, 0)
      messages.reset()
      messages.add(systemPrompt)
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
            if choice.message.content.isSome():
              echo choice.message.content.get().renderMarkdown()
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
                let cmd = args["cmd"].getStr()
                showToolCall($toolCall.function.name, %*{"cmd": cmd})
                if promptExecBash(cmd):
                  messages.add(initToolCallMessage(toolCall.id, callExecBash(cmd)))
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
