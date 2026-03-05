import std/options
import std/json

# Base types to build request/responses
type
  Role* = enum
    system = "system"
    user = "user"
    assistant = "assistant"
    tool = "tool"
  FinishReason* = enum
    stop = "stop"
    toolCalls = "tool_calls"
    length = "length"
    contentFilter = "content_filter"
  ToolDefinitionFunction* = object
    name*: string
    description*: string
    parameters*: JsonNode
  ToolDefinition* = object
    `type`*: string
    function*: ToolDefinitionFunction
  ToolCallFunction* = object
    name*: string
    arguments*: string
  ToolCall* = object
    id*: string
    `type`*: string
    function*: ToolCallFunction
  Message* = object
    role*: Role
    content*: Option[string]
    toolCalls*: Option[seq[ToolCall]]
    toolCallId*: Option[string]
  Choice* = object
    index*: int
    finishReason*: FinishReason
    message*: Message
  Usage* = object
    promptTokens*: int
    completionTokens*: int
    totalTokens*: int
  ApiError* = object
    code*: string
    message*: string
    `type`*: string

# Main API request/response types
type
  ChatErrorResponse* = object
    error*: ApiError
    requestId*: string
  ChatCompletionResponse* = object
    id*: string
    model*: string
    choices*: seq[Choice]
    usage*: Usage
  RequestBody* = object
    model*: string
    messages*: seq[Message]
    tools*: Option[seq[ToolDefinition]]
  ResponseKind* = enum
    ok, err
  ChatResponse* = object
    case kind*: ResponseKind
    of ok:
      response*: ChatCompletionResponse
    of err:
      error*: ChatErrorResponse

# Initialisers
proc initMessage*(role: Role, content: string): Message =
  return Message(role: role, content: some(content))

proc initRequestBody*(
  model: string,
  messages: seq[Message],
  tools: Option[seq[ToolDefinition]]
): RequestBody =
  return RequestBody(
    model: model,
    messages: messages,
    tools: tools
  )

proc initCustomError*(errorMessage: string): ChatErrorResponse =
  return ChatErrorResponse(
    error: ApiError(
      code: "unknown",
      message: errorMessage,
      `type`: "custom"
    ),
    requestId: ""
  )
