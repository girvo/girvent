import std/os
import std/files
import std/httpclient
import std/options
import std/json
import dotenv
import httpclient
import jsony
import noise
import ./openai
import ./tools

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

proc sendReq(): ChatResponse =
  try:
    let body = initRequestBody(modelId, messages, some(tools.allTools))
    let response = client.request(apiUrl, httpMethod = HttpPost, body = body.toJson())
    if response.status != "200 OK":
      let error = response.body.fromJson(ChatErrorResponse)
      return ChatResponse(kind: err, error: error)
    else:
      let parsed = response.body.fromJson(ChatCompletionResponse)
      return ChatResponse(kind: ok, response: parsed)
  except:
    let error = initCustomError("Could not parse body: " & getCurrentExceptionMsg())
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
      echo "Clearing thread..."
      messages.reset()
      messages.add(systemPrompt)
    else:
      messages.add(initMessage(Role.user, input))
      Styler.init(fgBlack, "\nThinking...\n").show()
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
          echo "\n" & choice.message.content.get()
        of contentFilter:
          echo "Hit a content filter, oop"
          discard messages.pop()
        of length:
          echo "Hit length condition, printing anyway:"
          echo choice.message.content.get()
          # TODO: Probably compact instead, right?
        of toolCalls:
          # Inner tool calling loop time
          # TODO: Eventually this should scatter-gather parallel calls
          var iterationCount = 0
          while true:
            inc iterationCount
            if iterationCount >= 30:
              Styler.init(fgRed, "Loop error: too many iterations " & $iterationCount).show()
              messages.setLen(currentLen)
              break
            if choice.message.content.isSome():
              echo choice.message.content.get()
            for toolCall in choice.message.toolCalls.get():
              let args = parseJson(toolCall.function.arguments)
              Styler.init(fgYellow, "[tool] Calling " & $toolCall.function.name & "\n").show()

              case toolCall.function.name
              of readFile:
                let fileContents = readFile(args["path"].getStr())
                messages.add(initToolCallMessage(toolCall.id, fileContents))
              of listDirectory:
                let folderContents = callListDirectory(args["path"].getStr())
                messages.add(initToolCallMessage(toolCall.id, folderContents))
            let res = sendReq()
            if res.kind == err:
              # Drop messages that caused the error
              messages.setLen(currentLen)
              Styler.init(fgRed, "Error returned: ").show()
              echo res.error.error.message
              break
            else:
              choice = res.response.choices[0]
              messages.add(choice.message)

              case choice.finishReason
              of stop:
                echo "\n" & choice.message.content.get()
                break # inner loop
              of toolCalls:
                continue
              else:
                echo "Unexpected finish reason: " & $choice.finishReason
                break
      of err:
        # Drop messages that caused the error
        messages.setLen(currentLen)
        Styler.init(fgRed, "Error returned: ").show()
        echo res.error.error.message
    echo ""

when isMainModule:
  runAgent()
