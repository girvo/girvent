#
#           nim-noise
#        (c) Copyright 2018 Andri Lim
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import posix, termios, terminal, std/exitprocs
import wtf8, basic

type
  IoCtx* = ref object
    termios: Termios
    rawMode: bool
    gotResize: bool
    atQuitRegistered: bool

var gIoCtx = IoCtx(nil)

proc newIoCtxAux(): IoCtx =
  new(result)
  result.rawMode = false

proc windowSizeChanged(x: cint) {.noconv.} =
  # do nothing here but setting this flag
  if gIoCtx == nil:
    gIoCtx.gotResize = true

proc installWindowChangeHandler() =
  const SIGWINCH = 28.cint
  var sa: Sigaction
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  sa.sa_handler = windowSizeChanged
  discard sigaction(SIGWINCH, sa)

proc newIoCtx*(): IoCtx =
  if gIoCtx == nil:
    gIoCtx = newIoCtxAux()
  result = gIoCtx
  when not defined(windows):
    installWindowChangeHandler()

proc disableRawMode*(ctx: IoCtx) =
  if ctx.rawMode:
    let fd = getFileHandle(stdin)
    if fd.tcSetAttr(TCSADRAIN, ctx.termios.addr) != -1:
      ctx.rawMode = false

proc resetTerminal() {.noconv.} =
  if gIoCtx != nil:
    gIoCtx.disableRawMode()

proc enableRawMode*(ctx: IoCtx): bool =
  template fatalError =
    errno = ENOTTY
    return false

  if not isAtty(stdin): fatalError()

  if not ctx.atQuitRegistered:
    exitprocs.addExitProc(resetTerminal)
    ctx.atQuitRegistered = true

  var raw: Termios
  let fd = getFileHandle(stdin)
  if fd.tcGetAttr(ctx.termios.addr) == -1: fatalError()

  # modify the original mode
  raw = ctx.termios

  # input modes: no break, no CR to NL, no parity check, no strip char,
  # no start/stop output control.
  raw.c_iflag = raw.c_iflag and not Cflag(BRKINT or ICRNL or
    INPCK or ISTRIP or IXON)

  # control modes - set 8 bit chars
  raw.c_cflag = raw.c_cflag or CS8

  # local modes - echoing off, canonical off, no extended functions,
  # no signal chars (^Z,^C)
  raw.c_lflag = raw.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)

  # control chars - set return condition: min number of bytes and timer.
  # We want read to return every single byte, without timeout.
  raw.c_cc[VMIN]  = chr(1)
  raw.c_cc[VTIME] = chr(0) # 1 byte, no timer

  # put terminal in raw mode after flushing
  if fd.tcSetAttr(TCSADRAIN, raw.addr) < 0: fatalError()
  ctx.rawMode = true
  result = true

# Read a UTF-8 sequence from the non-Windows keyboard and
# return the Unicode(char32) character it encodes
proc readUnicodeChar(): char32 =
  var
    utf8string: array[4, char8]
    utf8count = 0
    fd = getFileHandle(stdin)

  while true:
    var
      c: char8
      nread: int

    # Continue reading if interrupted by signal.
    while true:
      nread = read(fd, c.addr, 1)
      if not (nread == -1 and errno == EINTR): break

    if nread <= 0: return 0
    if c <= 0x7F: #short circuit ASCII
      return c.char32
    elif utf8count < utf8string.len:
      utf8string[utf8count] = c
      inc utf8count
      let res = wtf8_decode(utf8string, utf8count)
      if res.status == UTF8_ACCEPT:
        return res.codePoint.char32
    else:
      # this shouldn't happen: got four bytes but no UTF-8 character
      utf8count = 0

# This chunk of code does parsing of the escape sequences sent by various Linux
# terminals.
#
# It handles arrow keys, Home, End and Delete keys by interpreting the
# sequences sent by gnome terminal, xterm, rxvt, konsole, aterm and yakuake
# including the Alt and Ctrl key combinations that are understood by linenoise.
#
# The parsing uses tables, a bunch of intermediate dispatch Procs and a
# doDispatch loop that reads the tables and sends control to "deeper" Procs
# to continue the parsing.  The starting call to doDispatch(c, initialDispatch)
# will eventually return either a character(with optional CTRL and META bits set),
# or -1 if parsing fails, or zero if an attempt to read from the keyboard fails.
#
# This is rather sloppy escape sequence processing, since we're not paying
# attention to what the actual TERM is set to and are processing all key
# sequences for all terminals, but it works with the most common keystrokes
# on the most common terminals.  It's intricate, but the nested 'if'
# statements required to do it directly would be worse. This way has the
# advantage of allowing changes and extensions without having to touch
# a lot of code.

type
  EscapeCtx = object
    thisKey: char32
    readChar: proc(): char32 {.nimcall.}

  # This is a typedef for the Proc called by doDispatch()
  # It takes the current character as input, does any required processing
  # including reading more characters and calling other dispatch routines,
  # then eventually returns the final (possibly extended or special) character.
  DispatchProc = proc(ctx: var EscapeCtx, c: char32): char32 {.nimcall.}

# This dispatch routine is given a dispatch table and then farms work out to
# Procs listed in the table based on the character it is called with.
# The dispatch routines can read more input characters to decide what should
# eventually be returned. Eventually, a called routine returns either
# a character or -1 to indicate parsing failure.
#
# @chars: hold a list of characters to test for
# @dispatchTable: a list of routines to call if the character matches.
#   The dispatch routine list is one entry longer than the character list.
#   The final entry is used if no character matches.
proc doDispatch(ctx: var EscapeCtx, c: char32, chars: string, dispatchTable: openArray[DispatchProc]): char32 =
  assert(chars.len + 1 == dispatchTable.len)
  for i, x in chars:
    if x.char32 == c: return dispatchTable[i](ctx, c)
  dispatchTable[^1](ctx, c)

template doDispatch(ctx: var EscapeCtx, c: char32, x: typed): char32 =
  ctx.doDispatch(c, x[0], x[1])

template readOrRet() {.dirty.} =
  let c = ctx.readChar()
  if c == 0: return 0

# Final dispatch Procs -- return something
proc normalKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or c

proc upArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or UP_ARROW_KEY

proc downArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or DOWN_ARROW_KEY

proc rightArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or RIGHT_ARROW_KEY

proc leftArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or LEFT_ARROW_KEY

proc homeKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or HOME_KEY

proc endKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or END_KEY

# key labeled Backspace
proc deleteCharProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or ctrlChar('H')

proc ctrlUpArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or CTRL or UP_ARROW_KEY

proc ctrlDownArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or CTRL or DOWN_ARROW_KEY

proc ctrlRightArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or CTRL or RIGHT_ARROW_KEY

proc ctrlLeftArrowKeyProc(ctx: var EscapeCtx, c: char32): char32 =
  ctx.thisKey or CTRL or LEFT_ARROW_KEY

proc escFailureProc(ctx: var EscapeCtx, c: char32): char32 =
  beep()
  result = -1

# Kitty keyboard protocol modifier mapping.
# The modifier value is encoded as: value = 1 + modifiers
#   shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32
proc kittyModToFlags(modifier: char32): char32 =
  if modifier <= 1: return 0
  let mods = modifier - 1
  result = 0
  if (mods and 2) != 0: result = result or META   # alt
  if (mods and 4) != 0: result = result or CTRL   # ctrl

# Map a CSI <number> ~ functional key number to internal key constant.
proc mapFunctionalKey(ctx: var EscapeCtx, number: char32): char32 =
  case number
  of 1: ctx.thisKey or HOME_KEY
  of 3: ctx.thisKey or DELETE_KEY
  of 4: ctx.thisKey or END_KEY
  of 5: ctx.thisKey or PAGE_UP_KEY
  of 6: ctx.thisKey or PAGE_DOWN_KEY
  of 7: ctx.thisKey or HOME_KEY
  of 8: ctx.thisKey or END_KEY
  of 200: PASTE_START_KEY
  of 201: PASTE_END_KEY
  else: -1

# Map a CSI letter (A-H) to internal special key constant.
proc mapSpecialLetter(letter: char32): char32 =
  case letter
  of 'A'.char32: UP_ARROW_KEY
  of 'B'.char32: DOWN_ARROW_KEY
  of 'C'.char32: RIGHT_ARROW_KEY
  of 'D'.char32: LEFT_ARROW_KEY
  of 'H'.char32: HOME_KEY
  of 'F'.char32: END_KEY
  else: -1

# Map a Kitty CSI u sequence (or xterm modifyOtherKeys) to internal key.
proc mapCsiUKey(codepoint: char32, modifier: char32): char32 =
  let mods = kittyModToFlags(modifier)
  let isShift = modifier >= 2 and ((modifier - 1) and 1) != 0

  # Shift+Enter
  if codepoint == 13 and isShift:
    return SHIFT_ENTER_KEY

  # Ctrl key combos with ASCII letters → ctrl-char
  if (mods and CTRL) != 0:
    if codepoint >= 'a'.ord and codepoint <= 'z'.ord:
      return char32((mods and (not CTRL)) or ctrlChar(chr(codepoint.int - 32)))
    if codepoint >= 'A'.ord and codepoint <= 'Z'.ord:
      return char32((mods and (not CTRL)) or ctrlChar(chr(codepoint.int)))

  # Common keys
  case codepoint
  of 13: mods or ctrlChar('M')   # Enter
  of 9: mods or ctrlChar('I')    # Tab
  of 27:
    if mods == 0: ESC_KEY
    else: mods or ESC_KEY
  of 127: mods or ctrlChar('H')  # Backspace
  else:
    if codepoint >= 32 and codepoint < 0x110000:
      mods or codepoint
    else: -1

# Handle ESC [ (CSI) sequences using parameter accumulation.
# Supports: traditional xterm sequences, Kitty keyboard protocol (CSI u),
# and xterm modifyOtherKeys (CSI 27;mod;key~).
proc escLBracketProc(ctx: var EscapeCtx, c: char32): char32 =
  readOrRet()

  # Quick dispatch for unparameterized letter-terminated CSI sequences
  let specialKey = mapSpecialLetter(c)
  if specialKey >= 0:
    return ctx.thisKey or specialKey

  # Expect a digit to start parameter accumulation
  if c < '0'.char32 or c > '9'.char32:
    return -1

  # Accumulate semicolon-separated numeric parameters (up to 4)
  var params: array[4, char32]
  var paramCount = 1
  params[0] = c - '0'.char32

  while true:
    let ch = ctx.readChar()
    if ch == 0: return 0

    if ch >= '0'.char32 and ch <= '9'.char32:
      params[paramCount - 1] = params[paramCount - 1] * 10 + (ch - '0'.char32)
    elif ch == ';'.char32:
      if paramCount >= params.len: return -1
      inc paramCount
      params[paramCount - 1] = 0
    elif ch == 'u'.char32:
      # Kitty keyboard protocol: CSI <codepoint> [; <modifier>] u
      let codepoint = params[0]
      let modifier = if paramCount >= 2: params[1] else: 1.char32
      return mapCsiUKey(codepoint, modifier)
    elif ch == '~'.char32:
      case paramCount
      of 1:
        # CSI <number> ~ (traditional functional key)
        return ctx.mapFunctionalKey(params[0])
      of 2:
        # CSI <number> ; <modifier> ~ (modified functional key)
        let key = ctx.mapFunctionalKey(params[0])
        if key < 0: return -1
        let baseKey = key and (not ctx.thisKey)
        return ctx.thisKey or kittyModToFlags(params[1]) or baseKey
      of 3:
        # CSI 27 ; <modifier> ; <codepoint> ~ (xterm modifyOtherKeys)
        if params[0] == 27:
          return mapCsiUKey(params[2], params[1])
        return -1
      else:
        return -1
    else:
      # Letter terminator for special keys (A, B, C, D, H, F)
      let key = mapSpecialLetter(ch)
      if key >= 0:
        if paramCount >= 2:
          # CSI 1 ; <modifier> <letter> (modified arrow/home/end)
          return ctx.thisKey or kittyModToFlags(params[paramCount - 1]) or key
        else:
          return ctx.thisKey or key
      return -1

# Handle ESC O <char> escape sequences
let escODispatch = ("ABCDHFabcd", [
  upArrowKeyProc.DispatchProc, downArrowKeyProc,
  rightArrowKeyProc, leftArrowKeyProc, homeKeyProc,
  endKeyProc, ctrlUpArrowKeyProc, ctrlDownArrowKeyProc,
  ctrlRightArrowKeyProc, ctrlLeftArrowKeyProc, escFailureProc])

proc escOProc(ctx: var EscapeCtx, c: char32): char32 =
  readOrRet()
  ctx.doDispatch(c, escODispatch)

proc escShiftEnterProc(ctx: var EscapeCtx, c: char32): char32 =
  SHIFT_ENTER_KEY

proc setMetaProc(ctx: var EscapeCtx, c: char32): char32
let escDispatch = ("[O\r", [
  escLBracketProc.DispatchProc, escOProc, escShiftEnterProc, setMetaProc])

# Initial dispatch -- we are not in the middle of anything yet
proc escProc(ctx: var EscapeCtx, c: char32): char32 =
  if c == 0x1B:
    # we use timeout here to detect stand alone ESC KEY
    var
      s: TFdSet
      timeout: Timeval
      fd = getFileHandle(stdin)
    s.FD_ZERO
    fd.FD_SET(s)

    timeout.tv_sec = 0.Time
    timeout.tv_usec = 25

    let ret = posix.select(1, s.addr, nil, nil, timeout.addr)
    if ret == 1:
      # possible ESC escape sequence
      discard
    elif ret == -1:
      # failure
      return 0
    else:
      return ESC_KEY
  readOrRet()
  ctx.doDispatch(c, escDispatch)

let initialDispatch = ("\x1B\x7F", [
  escProc.DispatchProc, deleteCharProc, normalKeyProc])

# Special handling for the ESC key because it does double duty
proc setMetaProc(ctx: var EscapeCtx, c: char32): char32 =
  if c == 0x1B: # another ESC, stay in ESC processing mode
    return ESC_KEY
  #  readOrRet()
  #  return ctx.doDispatch(c, escDispatch)
  ctx.thisKey = META
  ctx.doDispatch(c, initialDispatch)

# read a keystroke or keychord from the keyboard, and  translate it
# into an encoded "keystroke".  When convenient, extended keys are
# translated into their simpler Emacs keystrokes, so an unmodified
# "left arrow" becomes Ctrl-B.
#
# A return value of zero means "no input available", and a return value of -1
# means "invalid key".
proc readChar*(): char32 =
  let c = readUnicodeChar()
  if c == 0: return 0

  # If DEBUG_KEYBOARD is set, then ctrl-^ puts us into a keyboard debugging mode
  # where we print out decimal and decoded values for whatever the "terminal" program
  # gives us on different keystrokes.  Hit ctrl-C to exit this mode.

  when defined(DEBUG_KEYBOARD):
    if c == ctrlChar('^'):
      echo "\nEntering keyboard debugging mode (on ctrl-^), press ctrl-C to exit this mode"
      var
        text = newString(3)
        keys: array[10, char8]
        fd = getFileHandle(stdin)

      template makeText(a, b, c: typed) =
        text[0] = a; text[1] = b; text[2] = c

      while true:
        let ret = read(fd, keys[0].addr, 10)
        if ret <= 0: echo "\nret: ", ret

        for i in 0..<ret:
          let
            key = keys[i].char32
            prefix = if key < 0x80: "" else: "0x80+"
            keyCopy = if key < 0x80: key else: key - 0x80

          if keyCopy >= '!'.ord and keyCopy <= '~'.ord:
            # printable
            makeText('\'', keyCopy.char, '\'')
          elif keyCopy == 0x20: makeText('S', 'P', 'C')
          elif keyCopy == 0x1B: makeText('E', 'S', 'C')
          elif keyCopy == 0x00: makeText('N', 'U', 'L')
          elif keyCopy == 0x7F: makeText('D', 'E', 'L')
          else: makeText('^', (keyCopy + 0x40).char, ' ')
          echo "$1 x$2 ($3$4)  " % [$key.int, toHex(key.int, 2), prefix, text]

        echo "\x1b[1G" # go to first column of new line

        # drop out of this loop on ctrl-C
        if keys[0] == ctrlChar('C'):
          echo "Leaving keyboard debugging mode (on ctrl-C)"
          stdout.flushFile
          return -2

  var ctx = EscapeCtx(thisKey: 0, readChar: readUnicodeChar)
  ctx.doDispatch(c, initialDispatch)

proc write32*(f: File, data: seq[char32], len: int) =
  let temp = utf32to8(data, len)
  f.write(temp)

proc clearToEnd*(f: File, len: int) =
  f.write("\e[J")

proc clearScreen*() =
  stdout.write("\x1b[H\x1b[2J")
  stdout.flushFile

#[proc getCursorPos(): tuple[x, y: int] =
  var
    cmd = "\e[6n"
    keys: array[20, char]
    fd = getFileHandle(stdin)

  discard fd.write(cmd.cstring, cmd.len)
  let numRead = read(fd, keys[0].addr, 10)
  if keys[0] != chr(0x1B) and keys[1] != '[':
    return (-1, -1)
  var pos = 2
  var y = 0
  while keys[pos] in Digits and pos < numRead:
    y = y * 10 + ord(keys[pos]) - ord('0')
    inc pos
  if keys[pos] != ';':
    return (-1, y)
  inc pos
  var x = 0
  while keys[pos] in Digits and pos < numRead:
    x = x * 10 + ord(keys[pos]) - ord('0')
    inc pos
  result = (x, y)
]#