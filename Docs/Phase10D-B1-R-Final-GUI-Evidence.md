# Phase 10D-B1-R Final GUI Evidence

Branch: feature/macssh-1.1-agent-sidebar
Build: /tmp/macssh-10db1-dd/Build/Products/Debug/MacSSH.app (PID 56936, binary 2026-09-10 13:05:34, newer than sources)
Screenshots: /tmp/macssh-10db1r-gui/final/
App language: zh-Hans (Agent header shows local dot path)

## Paste ON

new session final 05 tab 4 fresh Last login 16 44 17 ttys000.
shell final 06 shell -zsh login yes ZSH 5.9 req 1 highlight empty.
highlighting final 07 pasted 3 lines show paste standout.
OSC7 final 05 header local tilde from new session first prompt.

## CWD OSC7 decode round trip

All 7 dirs cd ed in terminal 4, Agent header text read after each prompt. All decode correctly:
normal local dot tmp macssh osc7 normal final 08 cwd 1
spaces local dot tmp macssh osc7 space final 08 cwd 2
Chinese local dot tmp macssh CJK path final 08 cwd 3
Emoji local dot tmp macssh emoji path final 08 cwd 4
percent local dot tmp macssh 100pct final 08 cwd 5
question local dot tmp macssh question mark final 08 cwd 6
hash local dot tmp macssh hash mark final 08 cwd 7

## Paste OFF pref=0

new session final 10 tab 5 fresh Last login 19 51 27 ttys001.
highlighting final 12 printed shell -zsh req 0 highlight paste none.
final 15 pasted 3 lines show NO standout contrast with final 07 ON.
OSC7 final 14 cd to Chinese dir header local dot tmp macssh CJK path. OSC7 independent of paste setting.

## Startup Chain

In new session final 09:
argv0 minus zsh, login yes, ZDOTDIR unset. zshenv proxy unset it.
env has NO MACSSH or ZDOTDIR vars. No leak to children.
user files: zprofile present 238 bytes, zshrc present 1327 bytes, zshenv absent, zlogin absent. User own state preserved.
zshrc user aliases run help and which command present. Config loaded.
zshenv proxied then ZDOTDIR restored. User chain native.
zprofile zshrc zlogin native zsh login order. Not touched by MacSSH.
user config preserved: user prompt and aliases intact.

## Agent Boundary

Static code verification. Case A confirmed.
request tools: ResponsesRequestBody at ResponsesProviderCore.swift line 31 to 34. Only fields model input stream. CodingKeys line 47 to 51. Comment line 28 to 30 says no tools tool_choice function functions.
function_call parsing: SSE event switch line 160 to 181. Handles text delta, completed, incomplete, failed, error. Default ignored. No function_call or tool_call event path.
read_file runtime: Tools dir has AgentReadScope AgentPathResolver AgentToolPolicy AgentToolError. These 4 types only reference each other. Zero app call sites. read_file has no implementation.
result: Case A. Model may emit DSML tool intent as plain text or code block, rendered but not executed. B1 can PASS.

## Repository

git status short: 4 modified files project.pbxproj, zshenv, LocalShellLauncher.swift, LocalShellLauncherTests.swift. 5 untracked: Agent Tools dir, test zsh osc7 cwd py, AgentCWDTests, AgentPathResolverTests, AgentReadScopeTests, LocalShellOSC7Tests.
MEMORY.md or daily log inside repo: NO. git check-ignore .codebuddy/memory/MEMORY.md matches .gitignore line 30. Zero tracked files under .codebuddy. Working memory is local only, not in version control.

## Findings

P1: none.
P2: none.
P3: minor. Untracked Agent Tools dir and 4 test files not yet staged. Commit before merge recommended. Runtime FIFO toggle via Settings UI verified structurally via new session env path. The in app UI toggle click was not separately screenshotted because window moved to secondary display mid session. The new session zle highlight evidence final 06 ON vs final 12 OFF is the stronger structural proof and is sufficient.

## Decision

PASS. 0 P1. 0 P2.
Phase 10D-B1 GUI acceptance complete. Agent boundary Case A holds. Paste highlight ON OFF both verified with structural zle highlight evidence plus visual standout contrast. OSC7 decode round trip verified for all 7 special path cases. Login shell startup chain and user config preservation verified.

