import std/os
import std/httpclient
import std/json
import std/options
import dotenv
import httpclient
import jsony
import openai

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
  messages.add(systemPrompt)

  while true:
    stdout.write("Input: ")
    let input = readLine(stdin)
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
      let res = sendReq()
      case res.kind
      of ok:
        echo "yep"
      of err:
        echo "nope"
    echo ""


when isMainModule:
  runAgent()
