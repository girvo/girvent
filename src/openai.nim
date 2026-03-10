## OpenAI-compatible LLM API type definitions for parsing

import std/options
import std/json
import jsony

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

  # Tool handling
  ToolName* {.pure.} = enum
    readFile = "read_file",
    listDirectory = "list_directory"
    writeFile = "write_file"
    execBash = "exec_bash"
    editFile = "edit_file"
    grep = "grep"
    lsp = "lsp"
  ToolDefinitionFunction* = object
    name*: ToolName
    description*: string
    parameters*: JsonNode
  ToolDefinition* = object
    `type`*: string
    function*: ToolDefinitionFunction
  ToolCallFunction* = object
    name*: ToolName
    arguments*: string
  ToolCall* = object
    id*: string
    `type`*: string
    function*: ToolCallFunction

  # Messages and choices
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

proc initToolCallMessage*(id: string, content: string): Message =
  return Message(
    role: tool,
    content: some(content),
    toolCallId: some(id)
  )

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

# These are handlers to serialise "toolCall" into "tool_call" and remove
# none() fields from the JSON output
proc dumpHook*(s: var string, v: Message) =
  s.add '{'
  s.add "\"role\":"
  s.dumpHook(v.role)
  if v.content.isSome:
    s.add ",\"content\":"
    s.dumpHook(v.content.get())
  else:
    s.add ",\"content\":null"
  if v.toolCalls.isSome:
    s.add ",\"tool_calls\":"
    s.dumpHook(v.toolCalls.get())
  if v.toolCallId.isSome:
    s.add ",\"tool_call_id\":"
    s.dumpHook(v.toolCallId.get())
  s.add '}'

proc dumpHook*(s: var string, v: Choice) =
  s.add '{'
  s.add "\"index\":"
  s.dumpHook(v.index)
  s.add ",\"finish_reason\":"
  s.dumpHook(v.finishReason)
  s.add ",\"message\":"
  s.dumpHook(v.message)
  s.add '}'

proc dumpHook*(s: var string, v: Usage) =
  s.add '{'
  s.add "\"prompt_tokens\":"
  s.dumpHook(v.promptTokens)
  s.add ",\"completion_tokens\":"
  s.dumpHook(v.completionTokens)
  s.add ",\"total_tokens\":"
  s.dumpHook(v.totalTokens)
  s.add '}'

proc dumpHook*(s: var string, v: ChatErrorResponse) =
  s.add '{'
  s.add "\"error\":"
  s.dumpHook(v.error)
  s.add ",\"request_id\":"
  s.dumpHook(v.requestId)
  s.add '}'
