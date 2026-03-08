import std/json
import std/terminal
import std/os
import std/strutils
import std/osproc
import openai
import noise

let bashPath = findExe("bash")
if bashPath == "":
  raise newException(OSError, "bash not found in PATH")

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
  writeFile = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.writeFile,
      description: "Writes to a file at a path with the given content",
      parameters: %*{
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The absolute or relative path to the file to write"
          },
          "content": {
            "type": "string",
            "description": "The full file contents to write to the filesystem"
          }
        },
        "required": ["path", "content"]
      }
    )
  )
  execBash = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.execBash,
      description: "Executes a bash command (with 'bash -c <your command>') and returns stdout and stderr",
      parameters: %*{
        "type": "object",
        "properties": {
          "cmd": {
            "type": "string",
            "description": "The bash command to execute"
          },
          "timeout": {
            "type": "integer",
            "description": "Timeout in seconds. Default 120. Set to 0 for no timeout (use for long-running commands like builds)."
          }
        },
        "required": ["cmd"]
      }
    )
  )

var allTools* = @[readFile, listDirectory, writeFile, execBash]

proc callListDirectory*(path: string): string =
  var res = ""
  try:
    for kind, entry in walkDir(path, relative=not path.isAbsolute):
      if kind == pcFile:
        res.add(entry & "\n")
      if kind == pcDir:
        res.add(entry & "/\n")
  except OSError as e:
    return "error: " & e.msg
  if res == "": return "empty directory"
  return res

const previewLines = 16

proc confirmPrompt(label: string): bool =
  var noise = Noise.init()
  noise.setPrompt(Styler.init(fgYellow, "  " & label & " [Y/n] "))
  if not noise.readLine(): return false
  if noise.getKeyType() == ktEsc: return false
  return noise.getLine() in ["", "y", "Y"]

proc promptWriteFile*(path: string, content: string): bool =
  let fullPath = if path.isAbsolute: path else: getCurrentDir() / path
  styledEcho(fgBlack, styleBright, "  → ", resetStyle, fullPath)
  echo ""
  let lines = content.splitLines()
  let preview = lines[0 ..< min(previewLines, lines.len)].join("\n")
  let truncated = lines.len > previewLines
  stdout.write(ansiStyleCode(styleDim) & preview)
  if truncated:
    stdout.write("\n  … (" & $(lines.len - previewLines) & " more lines)")
  stdout.write(ansiResetCode & "\n")
  echo ""
  return confirmPrompt("accept write?")

proc promptExecBash*(cmd: string): bool =
  echo ""
  styledEcho(ansiStyleCode(styleDim) & "  $ " & cmd & ansiResetCode)
  echo ""
  return confirmPrompt("execute?")

proc callWriteFile*(path: string, content: string): string =
  try:
    writeFile(path, content)
    return "written"
  except IOError as e:
    return "error: " & e.msg

const maxOutputLines = 200

proc truncateOutput(output: string): (string, string) =
  let lines = output.splitLines()
  let truncated = lines.len > maxOutputLines
  let body = lines[0 ..< min(maxOutputLines, lines.len)].join("\n")
  let suffix = if truncated: "\n… (" & $(lines.len - maxOutputLines) & " more lines truncated)" else: ""
  (body, suffix)

proc callExecBash*(cmd: string, timeout: int = 120): string =
  let tmpPath = getTempDir() / "girvent_" & $getCurrentProcessId() & ".out"
  defer:
    try: removeFile(tmpPath)
    except: discard
  try:
    # Redirect output to temp file to avoid pipe buffer deadlock with timeout
    let fullCmd = "(" & cmd & ") > " & quoteShell(tmpPath) & " 2>&1"
    let process = startProcess(bashPath, args = ["-c", fullCmd])
    let timeoutMs = if timeout <= 0: -1 else: timeout * 1000
    let exitCode = waitForExit(process, timeoutMs)

    if exitCode == -1:
      # Timed out — kill and return partial output
      kill(process)
      discard waitForExit(process)
      close(process)
      var partial = ""
      try: partial = readFile(tmpPath)
      except: discard
      let (body, _) = truncateOutput(partial)
      return "error: command timed out after " & $timeout & "s\n" & body

    close(process)
    let output = readFile(tmpPath)
    let (body, suffix) = truncateOutput(output)
    if exitCode != 0:
      return "exit code " & $exitCode & ":\n" & body & suffix
    return body & suffix
  except OSError as e:
    return "error: " & e.msg

when isMainModule:
  discard promptWriteFile(".", "my cool content")
