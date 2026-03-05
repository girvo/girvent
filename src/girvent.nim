import std/os
import std/httpclient
import std/options
import dotenv
import httpclient
import jsony
import openai
import noise

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
    let
      body = initRequestBody(modelId, messages, none(seq[ToolDefinition]))
      response = client.request(apiUrl, httpMethod = HttpPost, body = body.toJson())
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
      echo "\nThinking...\n"
      let
        currentLen = messages.len
        res = sendReq()
      case res.kind
      of ok:
        # This is "safe" enough as we always get choices len 1 back
        let choice = res.response.choices[0]
        messages.add(choice.message)

        case choice.finishReason
        of stop:
          echo choice.message.content.get()
        of contentFilter:
          echo "Hit a content filter, oop"
          discard messages.pop()
        of length:
          echo "Hit length condition, printing anyway:"
          echo choice.message.content.get()
          # TODO: Probably compact instead, right?
        of toolCalls:
          echo "Okay time for tool calls"
      of err:
        # Drop messages that caused the error
        messages.setLen(currentLen)
        Styler.init(fgRed, "Error returned:").show()
        echo res.error.error.message
    echo ""

when isMainModule:
  runAgent()
