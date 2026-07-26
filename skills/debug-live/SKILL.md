---
name: debug-live
description: Drive an interactive debugger (codelldb/LLDB) to investigate bugs, failing tests, wrong/null variable values, unexpected runtime behavior, and other "it doesn't work" reports. Use this skill whenever speculation about runtime behavior would be cheaper to *verify* by stepping through the code than to reason about. Pairs with the debugger-mcp MCP server.
license: MIT
allowed-tools:
  - add_breakpoint
  - add_logpoint
  - remove_breakpoint
  - clear_all_breakpoints
  - list_breakpoints
  - start_debugging
  - stop_debugging
  - restart_debugging
  - step_over
  - step_into
  - step_out
  - continue_execution
  - pause
  - get_variables_values
  - evaluate_expression
---

# debugger-mcp — Interactive Debugging Skill

This skill teaches an agent how to use the `debugger-mcp` MCP server effectively.
The server itself exposes only tools (with brief, behavioral descriptions); the
*workflow*, *root cause analysis framework*, and *tool-call patterns* live here.

---

## When to invoke this skill

Reach for this skill whenever you would otherwise *guess* at runtime behavior:

- Any reported bug, failing test, exception, or unexpected output.
- A variable holds an unexpected `null` / wrong type / wrong value.
- A function returns something the caller didn't expect.
- A code path executes (or fails to execute) when you didn't predict it would.
- You're about to read a large amount of code "trying to figure out what happens
  at runtime."

If you can step through the code in a few tool calls, do that instead of
speculating.

---

## Core workflow

1. **Set a starting breakpoint.** Use `add_breakpoint` with the file path and
   the 1-based line number you want to pause on. Place it at the earliest point
   that's still relevant to the suspected issue.

2. **Optionally add strategic breakpoints.** Decision points, error-handling
   branches, data boundaries (where input enters, where output is produced).

3. **Start the session.** Call `start_debugging` with the source file path and
   optional `workingDirectory`. The server launches codelldb and resumes until
   the first breakpoint is hit (the launch request uses `stopOnEntry:false`).

4. **Navigate and inspect.** Use `step_over`, `step_into`, `step_out`,
   `continue_execution` to move through code. Use `pause` to interrupt a
   freely-running program. Use `get_variables_values` to see local/global
   state and `evaluate_expression` to test hypotheses live.

5. **Find the root cause** (see framework below). Don't stop at the first
   wrong thing you see — trace it back to *why*.

6. **Clean up.** Call `clear_all_breakpoints` when you're done so you don't
   pollute the next session, and `stop_debugging` if the session is still
   active.

---

## Root cause analysis framework

### Never stop at symptoms — always find the root cause

| Concept | Definition | Example |
|---------|------------|---------|
| **Symptom** | What you observed that's wrong | "Variable `user` is null on line 45" |
| **Root cause** | *Why* the symptom occurred | "`getUserById()` returned null because the DB query failed because the connection string is wrong" |

### Investigation process

1. **Identify the symptom.** What exactly is wrong? Which line, which variable,
   which thrown exception? Record the current state.

2. **Ask "why?"** Why is this value wrong? Why did this function return this?
   Why did this condition evaluate this way?

3. **Trace backwards.** Set a breakpoint *before* the symptom, restart, and
   step forward to watch where the wrong state first appears.

4. **Repeat until you reach the origin.** Keep asking "why" until you hit a
   fundamental cause — usually where data enters the system, a config is read,
   or an assumption is first violated.

### Signs you're stopping too early

- You found a `null` variable but didn't check why it's that way.
- You see an error but didn't trace where it originates.
- You identified "bad data" but didn't find why the data is bad.
- You found a failing condition but didn't check why it fails.

### Signs you've found the root cause

- You can explain the complete chain from root cause → symptom.
- Fixing this one thing would prevent the symptom from occurring.
- The issue is at a fundamental level (data input, configuration, logic invariant).
- You understand not just *what* is wrong but *why* it's wrong.

### Practical examples

**Null variable:**
```
Symptom:      user is null on line 45
Investigate:  set breakpoint in getUserById(), restart, step through
              → DB query returns null
              → connection parameters are wrong
Root cause:   connection string in config file is incorrect
```

**Function exits early:**
```
Symptom:      processOrder() exits early with "invalid payment status"
Investigate:  breakpoint at validation check
              → payment status is "pending" not "completed"
              → status never updated because callback never fires
Root cause:   webhook endpoint misconfigured in payment gateway dashboard
```

**Unexpected value:**
```
Symptom:      calculation result is NaN
Investigate:  check input parameters
              → one input is a string, not a number
              → parseFloat() failed on "$42.00"
Root cause:   sanitization function doesn't strip currency symbols
```

---

## Breakpoint strategy

- **Start broad, then narrow.** Begin at the entry point of the suspect
  function. As you isolate the issue, add tighter breakpoints around the
  problematic region.

- **Use line numbers.** `add_breakpoint` takes a 1-based `line`; re-check the
  line after edits since numbers shift when code changes.

- **Prefer logpoints for loops/hot paths.** When you want to observe how a
  value evolves across many iterations without stopping, use `add_logpoint`
  with `{expression}` interpolation (e.g. `iter [{i}] total={total}`).
  Logpoints also avoid distorting timing-sensitive code.

- **Don't overuse breakpoints.** A handful of well-placed pauses beats dozens
  of noisy ones. After each session, `clear_all_breakpoints` to start fresh.

---

## Tool-call patterns

### Investigating a bug in `calculate.rs`

```
add_breakpoint  fileFullPath=/repo/src/calculate.rs  line=42
start_debugging fileFullPath=/repo/src/calculate.rs  workingDirectory=/repo
step_over
get_variables_values scope=local
evaluate_expression  expression="type_of(raw)"
step_into
# … iterate until root cause found …
clear_all_breakpoints
stop_debugging
```

### Debugging a C program

```
add_breakpoint  fileFullPath=/repo/src/main.c  line=15
start_debugging fileFullPath=/repo/src/main.c  workingDirectory=/repo
continue_execution
# breakpoint hit
get_variables_values
step_over
evaluate_expression expression="buffer[0]"
```

### Verifying a fix without relaunch

```
restart_debugging fileFullPath=/repo/src/main.c  workingDirectory=/repo
# session restarts; breakpoints persist
continue_execution
```

---

## Language-specific notes

debugger-mcp uses codelldb, which debugs **native code**:

| Language | Support | Notes |
|----------|---------|-------|
| C | ✓ | Compile with `-g` |
| C++ | ✓ | Compile with `-g` |
| Rust | ✓ | `cargo build` generates debug info by default in debug mode |
| Zig | ✓ | Build with default debug mode |
| Swift | ✓ | Via LLDB |
| Objective-C | ✓ | Via LLDB |
| Assembly | ✓ | Via LLDB |

For **interpreted languages** (Python, JavaScript, Java, C#), use a different
debug adapter (e.g. debugpy, pwa-node, debugger-mcp only supports codelldb).

---

## Things to avoid

- ❌ **Speculating about runtime values when you could just inspect them.**
  That's what `get_variables_values` and `evaluate_expression` are for.

- ❌ **Calling `start_debugging` without first setting a breakpoint.**
  The program will run to completion and you'll learn nothing.

- ❌ **Stopping at the first wrong value you find.** That's a symptom.
  Trace it back.

- ❌ **Leaving breakpoints set across sessions.** Future runs will pause
  in unexpected places. Always `clear_all_breakpoints` when done.

- ❌ **Using `start_debugging` without a `workingDirectory` when the
  executable or shared libraries are relative to a project root.**
  codelldb needs the correct working directory to resolve paths.

- ❌ **Expecting event-driven notifications.** debugger-mcp is poll-based;
  after a step/continue, the operation completes but the server doesn't
  push state changes. Always follow up with `get_variables_values` to
  confirm where you are.
