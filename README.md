# maki-codex

A Maki plugin providing features specific to your ChatGPT Codex subscription.

## Setup

Add this to `~/.config/maki/init.lua`:

```lua
maki.pack.add({ "https://github.com/dkarvik/maki-codex.git" })
```

Sign in to Maki's OpenAI provider and approve the package permissions.

## Tools

* `codex_search`: Perform a web search with codex
* `image_generation`: Generate an image

## Commands

`/codex-reset`: View and redeem your codex reset tokens
