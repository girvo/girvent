import std/json
import std/terminal
import std/os
import std/strutils
import std/osproc
import openai
import noise
import md_ansi

let bashPath = findExe("bash")
if bashPath == "":
  raise newException(OSError, "bash not found in PATH")

let rgPath = findExe("rg")
if rgPath == "":
  raise newException(OSError, "rg (ripgrep) not found in PATH")

const
  grepTimeoutMs = 30_000
  grepMaxMatchesPerFile = 500  # Per-file limit; truncateOutput caps total output

let
  readFile = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.readFile,
      description: "Reads a file on the users filesystem and returns the contents with line numbers. Line numbers are prefixed for reference only (e.g. '  1| ...') and are not part of the file content.",
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
      description: "Lists the files and subdirectories within a given directory. Each entry is prefixed: f = file, d = directory, s = symlink. Only call this on directories, not on files.",
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

  editFile = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.editFile,
      description: "Replaces a unique substring in a file. The old_string must match exactly once in the file. Prefer this over write_file for modifying existing files — include enough surrounding context in old_string to ensure a unique match.",
      parameters: %*{
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The absolute or relative path to the file to edit"
          },
          "old_string": {
            "type": "string",
            "description": "The exact substring to find and replace. Must match exactly once in the file."
          },
          "new_string": {
            "type": "string",
            "description": "The replacement string"
          }
        },
        "required": ["path", "old_string", "new_string"]
      }
    )
  )

  grepTool = ToolDefinition(
    `type`: "function",
    function: ToolDefinitionFunction(
      name: ToolName.grep,
      description: "Search file contents with a regex pattern using ripgrep. Returns matching lines with file paths and line numbers. Use to find symbols, patterns, or text across the codebase.",
      parameters: %*{
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "The regex pattern to search for"
          },
          "path": {
            "type": "string",
            "description": "Directory or file to search in. Defaults to the working directory."
          },
          "glob": {
            "type": "string",
            "description": "File glob filter, e.g. \"*.nim\", \"*.py\". Only search files matching this pattern."
          }
        },
        "required": ["pattern"]
      }
    )
  )

var allTools* = @[readFile, listDirectory, writeFile, editFile, grepTool, execBash]

proc callReadFile*(path: string): string =
  let content = readFile(path)
  # Detect binary: null byte in first 8KB (same heuristic as git)
  for i in 0 ..< min(8192, content.len):
    if content[i] == '\0':
      return "error: '" & path & "' is a binary file, not a text file."
  let
    lines = content.splitLines()
    width = ($lines.len).len
  var res = ""
  for i, line in lines:
    res.add(align($(i + 1), width) & "| " & line & "\n")
  return res

proc callListDirectory*(path: string): string =
  if fileExists(path):
    return "error: '" & path & "' is a file, not a directory. Use read_file to read it."
  var res = ""
  try:
    for kind, entry in walkDir(path, relative=true):
      let (prefix, suffix) = case kind
        of pcFile: ("f ", "")
        of pcDir: ("d ", "/")
        of pcLinkToFile: ("s ", "")
        of pcLinkToDir: ("s ", "/")
      res.add(prefix & entry & suffix & "\n")
  except OSError as err:
    return "error: " & err.msg
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
  styledEcho(ansiForegroundColorCode(c256Gray), "  → ", resetStyle, fullPath)
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

proc promptEditFile*(path: string, oldString: string, newString: string): bool =
  let fullPath = if path.isAbsolute: path else: getCurrentDir() / path
  styledEcho(ansiForegroundColorCode(c256Gray), "  → ", resetStyle, fullPath)
  echo ""
  let oldLines = oldString.splitLines()
  let newLines = newString.splitLines()
  for line in oldLines:
    styledEcho(fgRed, "  - ", resetStyle, ansiStyleCode(styleDim), line, ansiResetCode)
  for line in newLines:
    styledEcho(fgGreen, "  + ", resetStyle, ansiStyleCode(styleDim), line, ansiResetCode)
  echo ""
  return confirmPrompt("accept edit?")

proc callEditFile*(path: string, oldString: string, newString: string): string =
  try:
    let content = readFile(path)
    let count = content.count(oldString)
    if count == 0:
      return "error: old_string not found in file"
    if count > 1:
      return "error: old_string matches " & $count & " times (must be unique)"
    let newContent = content.replace(oldString, newString)
    writeFile(path, newContent)
    return "edited"
  except IOError as err:
    return "error: " & err.msg

const maxOutputLines = 200

proc truncateOutput(output: string): (string, string) =
  let lines = output.splitLines()
  let truncated = lines.len > maxOutputLines
  let body = lines[0 ..< min(maxOutputLines, lines.len)].join("\n")
  let suffix = if truncated: "\n… (" & $(lines.len - maxOutputLines) & " more lines truncated)" else: ""
  (body, suffix)

proc callGrep*(pattern: string, path: string = ".", glob: string = ""): string =
  if not fileExists(path) and not dirExists(path):
    return "error: path does not exist: " & path

  # Use temp file to avoid pipe buffer deadlock (same pattern as callExecBash)
  let tmpPath = getTempDir() / "girvent_grep_" & $getCurrentProcessId() & ".out"
  let errPath = getTempDir() / "girvent_grep_" & $getCurrentProcessId() & "_err.out"
  defer:
    try: removeFile(tmpPath)
    except: discard
    try: removeFile(errPath)
    except: discard

  var args = @["--vimgrep", "--color", "never", "--max-count", $grepMaxMatchesPerFile]
  if glob != "":
    args.add("--glob")
    args.add(glob)
  args.add(pattern)
  args.add(path)

  try:
    let fullCmd = rgPath & " " & args.join(" ") & " > " & quoteShell(tmpPath) & " 2> " & quoteShell(errPath)
    let process = startProcess(bashPath, args = ["-c", fullCmd], options = {poUsePath})
    let exitCode = waitForExit(process, grepTimeoutMs)

    if exitCode == -1:
      kill(process)
      discard waitForExit(process)
      close(process)
      return "error: grep timed out after " & $(grepTimeoutMs div 1000) & "s"

    close(process)

    var stderr = ""
    try: stderr = readFile(errPath)
    except: discard

    let output = if fileExists(tmpPath): readFile(tmpPath) else: ""

    if exitCode == 1:
      return "no matches found"

    if exitCode != 0:
      if stderr.strip().len > 0:
        return "error: " & stderr.strip()
      else:
        return "error: rg exited with code " & $exitCode

    if output == "":
      return "no matches found"

    let (body, suffix) = truncateOutput(output)
    return body & suffix

  except OSError as err:
    return "error: " & err.msg

proc callWriteFile*(path: string, content: string): string =
  try:
    writeFile(path, content)
    return "written"
  except IOError as err:
    return "error: " & err.msg

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
  except OSError as err:
    return "error: " & err.msg

when isMainModule:
  discard promptWriteFile(".", "my cool content")
