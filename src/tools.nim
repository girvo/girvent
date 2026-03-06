import std/json
import std/os
import std/sequtils
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

proc callListDirectory*(path: string): string =
  var res = ""
  for kind, path in walkDir(path, relative=true):
    if kind == pcFile:
      res.add(path & "\n")
    if kind == pcDir:
      res.add(path & "/\n")
  return res

when isMainModule:
  callListDirectory(".")
