# Custom coding agent

Rough arch in psuedocode:

```
messages = [system_prompt]

loop:
    input = read_user_input()
    if input is quit command: break
    
    append { role: "user", content: input } to messages
    
    # inner agent loop - keeps going until model is done
    loop:
        response = call_api(messages, tool_definitions)
        
        if response is error:
            print error
            # pop the last user message so history stays clean
            break to outer loop
        
        message = response.choices[0].message
        append message to messages  # always append, whether text or tool_calls
        
        if message.finish_reason is "stop":
            print message.content
            break to outer loop
        
        if message.finish_reason is "tool_calls":
            for each tool_call in message.tool_calls:
                result = execute_tool(tool_call.function.name, tool_call.function.arguments)
                append { role: "tool", tool_call_id: tool_call.id, content: result } to messages
            
            continue inner loop  # let model see the results
```