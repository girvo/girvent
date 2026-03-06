import std/terminal
import std/strutils
import std/lists
import markdown

proc renderChildren(token: Token): string

proc renderAnsi*(token: Token): string =
  var output = ""

  if token of Heading:
    let heading = Heading(token)
    let children = renderChildren(token)
    if heading.level == 1:
      output.add(ansiForegroundColorCode(fgCyan) & ansiStyleCode(styleBright) & ansiStyleCode(styleUnderscore))
      output.add(children.toUpperAscii())
      output.add(ansiResetCode & "\n")
    elif heading.level == 2:
      output.add(ansiForegroundColorCode(fgCyan) & ansiStyleCode(styleBright))
      output.add(children)
      output.add(ansiResetCode & "\n")
    else:
      output.add(ansiForegroundColorCode(fgCyan))
      output.add(children)
      output.add(ansiResetCode & "\n")

  elif token of Strong:
    output.add(ansiStyleCode(styleBright))
    output.add(renderChildren(token))
    output.add(ansiResetCode)

  elif token of Em:
    output.add(ansiStyleCode(styleItalic))
    output.add(renderChildren(token))
    output.add(ansiResetCode)

  elif token of CodeSpan:
    output.add(ansiForegroundColorCode(fgYellow))
    output.add(renderChildren(token))
    output.add(ansiResetCode)

  elif token of CodeBlock:
    let codeBlock = CodeBlock(token)
    if codeBlock.info.len > 0:
      output.add(ansiStyleCode(styleDim) & codeBlock.info & ansiResetCode & "\n")
    output.add(ansiForegroundColorCode(fgBlue))
    output.add(token.doc)
    output.add(ansiResetCode & "\n")

  elif token of Paragraph:
    output.add(renderChildren(token))
    output.add("\n")

  elif token of Ul:
    for child in token.children:
      output.add("  • ")
      if child of Li:
        for inner in child.children:
          if inner of Paragraph:
            output.add(renderChildren(inner))
          else:
            output.add(renderAnsi(inner))
      else:
        output.add(renderAnsi(child))
      output.add("\n")

  elif token of Ol:
    var index = 1
    if token of Ol:
      index = Ol(token).start
    for child in token.children:
      output.add("  " & $index & ". ")
      if child of Li:
        for inner in child.children:
          if inner of Paragraph:
            output.add(renderChildren(inner))
          else:
            output.add(renderAnsi(inner))
      else:
        output.add(renderAnsi(child))
      output.add("\n")
      inc(index)

  elif token of Li:
    output.add("  • ")
    output.add(renderChildren(token))
    output.add("\n")

  elif token of Link:
    let link = Link(token)
    output.add(ansiStyleCode(styleUnderscore) & ansiForegroundColorCode(fgGreen))
    output.add(renderChildren(token))
    output.add(ansiResetCode)
    output.add(ansiStyleCode(styleDim) & " (" & link.url & ")" & ansiResetCode)

  elif token of Blockquote:
    output.add(ansiForegroundColorCode(fgMagenta) & "│ ")
    output.add(renderChildren(token))
    output.add(ansiResetCode)

  elif token of ThematicBreak:
    output.add("─".repeat(40) & "\n")

  elif token of SoftBreak:
    output.add(" ")

  elif token of HardBreak:
    output.add("\n")

  elif token of Text:
    output.add(token.doc)

  elif token of Document:
    output.add(renderChildren(token))

  else:
    output.add(renderChildren(token))

  return output

proc renderChildren(token: Token): string =
  var output = ""
  for child in token.children:
    output.add(renderAnsi(child))
  return output

proc renderMarkdown*(input: string): string =
  var root = Document()
  discard markdown(input, root = root)
  return renderAnsi(root)

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
