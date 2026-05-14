<p align="center">
  <img src="icon.png" width="128" height="128" alt="flock">
</p>

# flock

[![macOS](https://img.shields.io/badge/macOS-13%2B-blue)](https://github.com/baahaus/flock/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/baahaus/flock)](https://github.com/baahaus/flock/releases/latest)
[![GitHub stars](https://img.shields.io/github/stars/baahaus/flock)](https://github.com/baahaus/flock/stargazers)

**let your agents loose.**

[baahaus.github.io/flock](https://baahaus.github.io/flock/)

flock is a tiny, beautiful macOS app that lets you run as many Claude Code sessions as you want, all at once, all in one window. it also gives you shell panes and editable markdown panes alongside them. watch them think, read, edit, and build in real time. it's like having a team of programmers that never sleeps.

you open flock. you press `⌘T` a few times. suddenly four claudes are working on four different things and you're just... watching. it's kind of mesmerizing honestly.

<p align="center">
  <img src="screenshot.png" width="900" alt="flock running 7 parallel sessions">
</p>

<br>

## get it

grab the `.pkg` installer or `.zip` from [releases](https://github.com/baahaus/flock/releases) and you're done.

support lives on [GitHub issues](https://github.com/baahaus/flock/issues). privacy details live at [baahaus.github.io/flock/privacy.html](https://baahaus.github.io/flock/privacy.html).

<br>

## what you get

### panes

flock has three kinds of panes. they tile themselves automatically -- 1 fills the screen, 2 split in half, 4 make a grid. split horizontal, split vertical, maximize one, whatever you want. it figures it out.

- **claude panes** run full Claude Code sessions with real-time activity detection, state indicators (thinking, working, waiting, idle), and a change log overlay (`⌘⇧L`) showing every file read, edit, and command.
- **shell panes** are regular terminals with autosuggestions baked in.
- **markdown panes** let you open or create `.md` files, edit them directly, and autosave back to disk. external changes are detected and you get a clean conflict resolution dialog.

### command palette

`⌘K` opens everything. new panes, markdown files, themes, layouts, broadcast mode, pane navigation. fuzzy search, keyboard-driven. if you've used raycast or arc you already know how this works.

### broadcast mode

`⌘⇧B` -- type once, every pane hears it. useful when you want all your claudes to know something at the same time.

### find

`⌘F` searches inside the current terminal pane with live highlighting and prev/next navigation. `⌘⇧F` opens global find that searches across every open pane simultaneously -- terminals and markdown -- with results showing match counts per pane.

### wren compression

toggle on prompt compression in preferences and flock runs your messages through [wren](https://github.com/baahaus/wren) before sending. compresses prompts 50-80%, preserving meaning while saving tokens. works on paste in terminal panes.

### usage tracking

tracks your daily token usage and cost across all claude sessions. shows input, output, cache read, and cache write tokens with model-specific pricing. monitors plan limits from the Anthropic API. toggle it on in preferences to see it in the status bar.

### themes

7 built-in themes, each with a complete color palette including terminal ANSI colors:

**flock** (warm cream) -- **claude** (terracotta) -- **midnight** (dark blue) -- **ember** (charred brown) -- **vesper** (indigo) -- **overcast** (cool grey) -- **linen** (light)

### session restore

close the app, open it later, everything's still there. your layout, your panes, your working directories, right where you left them.

### notifications & sounds

flock taps you on the shoulder when a session finishes something. native macOS notifications with optional sound effects. long-running commands (>10s) trigger a notification automatically so you can go get coffee.

### global hotkey

`Ctrl+`` summons flock from anywhere. hit it again to hide. customizable key and modifiers.

### auto-updater

checks for new versions on launch, shows a formatted changelog when you update, and links you straight to the download. toggle it off if you want.

<br>

## keyboard shortcuts

flock is keyboard-first. your hands never leave the keys.

| | |
|---|---|
| `⌘T` | new claude |
| `⌘⇧T` | new shell |
| `⌘W` | close pane |
| `⌘1`--`⌘9` | jump to pane |
| `⌘←→↑↓` | navigate panes |
| `⌘↩` | maximize / restore |
| `⌘D` | split horizontal |
| `⌘⇧D` | split vertical |
| `⌘K` | command palette |
| `⌘⇧B` | broadcast mode |
| `⌘⇧L` | change log overlay |
| `⌘F` | find in pane |
| `⌘⇧F` | find in all panes |
| `⌘G` | find next |
| `⌘⇧G` | find previous |

<br>

## build it yourself

you'll need xcode (swift 5.9+).

```bash
git clone https://github.com/baahaus/flock.git
cd flock
./build.sh
```

that's it. app goes to `/Applications`, cli goes to `flock`.

<br>

## under the hood

native swift. no electron. terminal panes are powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), and markdown panes are native editable text views that autosave to disk. agent mode talks to claude code over `stream-json` and parses every event in real time to build the timelines and kanban board. prompt compression runs through [wren](https://github.com/baahaus/wren), a LoRA fine-tuned model on Apple Silicon via MLX. it's fast because it's not pretending to be a website.

<br>

## why "flock"

a flock of claudes. working together. that's it. that's the name.

<br>

<p align="center">
  <sub>made by <a href="https://github.com/baahaus">baahaus</a></sub>
</p>
