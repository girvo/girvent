# Markdown -> ANSI (terminal) parser
import std/terminal
import std/strutils
import std/lists
import markdown

type Color256* = enum
  c256SoftOrange = 215
  c256DarkGray   = 237
  c256DimGray    = 240  # dim gray for very secondary text
  c256Gray       = 245  # visible gray for secondary text (replaces fgBlack+styleBright)

proc ansiForegroundColorCode*(c: Color256): string = "\e[38;5;" & $ord(c) & "m"
proc ansiBackgroundColorCode*(c: Color256): string = "\e[48;5;" & $ord(c) & "m"

proc renderChildren(token: Token, resetTo: string = ansiResetCode): string

proc renderAnsi*(token: Token, resetTo: string = ansiResetCode): string =
  var output = ""

  if token of Heading:
    let heading = Heading(token)
    let (color, reset) = block:
      if heading.level == 1:
        (ansiForegroundColorCode(fgCyan) & ansiStyleCode(styleBright) & ansiStyleCode(styleUnderscore), ansiResetCode)
      elif heading.level == 2:
        (ansiForegroundColorCode(fgCyan) & ansiStyleCode(styleBright), ansiResetCode)
      else:
        (ansiForegroundColorCode(fgCyan), ansiResetCode)
    let children = renderChildren(token, color)
    output.add(color)
    if heading.level == 1:
      output.add(children.toUpperAscii())
    else:
      output.add(children)
    output.add(reset & "\n")

  elif token of Strong:
    let bold = resetTo & ansiStyleCode(styleBright)
    output.add(ansiStyleCode(styleBright))
    output.add(renderChildren(token, bold))
    output.add(resetTo)

  elif token of Em:
    output.add(ansiStyleCode(styleItalic))
    output.add(renderChildren(token, resetTo & ansiStyleCode(styleItalic)))
    output.add(resetTo)

  elif token of CodeSpan:
    output.add(ansiForegroundColorCode(c256SoftOrange))
    output.add(token.doc)
    output.add(ansiResetCode & resetTo)

  elif token of CodeBlock:
    let codeBlock = CodeBlock(token)
    if codeBlock.info.len > 0:
      output.add(ansiStyleCode(styleDim) & codeBlock.info & ansiResetCode & "\n")
    output.add(ansiForegroundColorCode(fgBlue))
    output.add(token.doc)
    output.add(ansiResetCode & "\n")

  elif token of Paragraph:
    output.add(renderChildren(token))
    output.add("\n\n")

  elif token of Ul:
    for child in token.children:
      output.add("  • ")
      var item = ""
      if child of Li:
        for inner in child.children:
          if inner of Paragraph:
            item.add(renderChildren(inner))
          else:
            item.add(renderAnsi(inner))
      else:
        item.add(renderAnsi(child))
      output.add(item.strip(leading = false, chars = {'\n'}))
      output.add("\n")
    output.add("\n\n")

  elif token of Ol:
    var index = 1
    if token of Ol:
      index = Ol(token).start
    for child in token.children:
      output.add("  " & $index & ". ")
      var item = ""
      if child of Li:
        for inner in child.children:
          if inner of Paragraph:
            item.add(renderChildren(inner))
          else:
            item.add(renderAnsi(inner))
      else:
        item.add(renderAnsi(child))
      output.add(item.strip(leading = false, chars = {'\n'}))
      output.add("\n")
      inc(index)
    output.add("\n\n")

  elif token of Li:
    output.add("  • ")
    output.add(renderChildren(token))
    output.add("\n")

  elif token of Link:
    let link = Link(token)
    output.add(ansiStyleCode(styleUnderscore) & ansiForegroundColorCode(fgGreen))
    output.add(renderChildren(token, resetTo))
    output.add(resetTo)
    if link.url.len > 0 and not link.url.startsWith("#"):
      output.add(ansiStyleCode(styleDim) & " (" & link.url & ")" & resetTo)

  elif token of Blockquote:
    output.add(ansiForegroundColorCode(fgMagenta) & "│ ")
    output.add(renderChildren(token, ansiForegroundColorCode(fgMagenta)))
    output.add(ansiResetCode & "\n\n")

  elif token of ThematicBreak:
    output.add("─".repeat(40) & "\n\n")

  elif token of SoftBreak:
    output.add(" ")

  elif token of HardBreak:
    output.add("\n")

  elif token of Text:
    output.add(token.doc)

  elif token of Document:
    output.add(renderChildren(token))

  else:
    output.add(renderChildren(token, resetTo))

  return output

proc renderChildren(token: Token, resetTo: string = ansiResetCode): string =
  var output = ""
  for child in token.children:
    output.add(renderAnsi(child, resetTo))
  return output

# The actual markdown -> ansi renderer
proc renderMarkdown*(input: string): string =
  var root = Document()
  discard markdown(input, root = root)
  return renderAnsi(root).strip(leading = false, chars = {'\n'})

when isMainModule:
  let testInput = """
# Heading 1

## Heading 2

### Heading 3

This is a paragraph with **bold text** and *italic text* and `inline code`.

- First item
- Second item
- Third item with **bold**

1. Numbered one
2. Numbered two
3. Third with `code`
```nim
proc hello() =
  echo "world"
```

> This is a blockquote

---

Some final text with a [link](https://example.com) and more **bold** words.
"""

  echo renderMarkdown(testInput)
