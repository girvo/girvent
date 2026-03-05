import std/json
import openai


let
  readFile = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.readFile,
      description: "Reads a file on the users filesystem and returns the contents",
      parameters: %*{
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The absolute or relative path to the file to read"
          }
        },
        "required": ["path"]
      }
    )
  )
  listDirectory = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.listDirectory,
      description: "Lists the files and subdirectories within a given directory",
      parameters: %*{
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The absolute or relative path to the directory to list"
          }
        },
        "required": ["path"]
      }
    )
  )

var allTools* = @[readFile, listDirectory]
