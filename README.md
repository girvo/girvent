# Girvent

A minimal coding agent harness in Nim.

## Requirements

- Nim >= 2.2.8
- [Nimble](https://github.com/nim-lang/nimble)

## Setup

1. Install dependencies:
   ```bash
   nimble install
   ```

2. Create a `.env` file with your ([Alibaba Model Studio Coding Plan](https://www.alibabacloud.com/en/campaign/ai-scene-coding?_p_lc=1)) API key:
   ```bash
   API_KEY=your_api_key_here
   ```
   (or put it in your `.bashrc` etc via `export GIRVENT_API_KEY=sk-etc..`)

## Build

```bash
nimble build
```

## Install

```bash
ln -s $PWD/girvent /usr/local/bin/girvent
```
(or similar, up to you but if you want to use it outside of where you built it, this is needed)

## Usage

Run the agent:

```bash
./girvent
```

### Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/clear` | Clear conversation history |
| `/context` | Show token usage |
| `/model` | Show or switch model |
| `/quit` | Exit |

### Tools

The agent has access to:
- `read_file` - Read file contents
- `write_file` - Write to a file
- `list_directory` - List directory contents
- `exec_bash` - Run shell commands
