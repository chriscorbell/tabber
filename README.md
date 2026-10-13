# Tabber

Tabber predicts your next words in any Mac app and shows them as ghost text right at the caret, in the app's own font. Press **Tab** to take the next word, press the **key above Tab** to take the whole suggestion, or just keep typing. Everything runs on your Mac with a small open model; nothing you type leaves it.

It's free and open source (MIT).

## How it feels

- **One word per Tab.** Suggestions are short (2–4 words by default) because the first word or two is what you usually want. Tab takes one word at a time, so you keep control.
- **Type through it.** When your next letter matches the suggestion, it just shrinks. When it doesn't, it disappears and a better one replaces it a few milliseconds later.
- **Looks native.** Ghost text uses the field's own font, size, and a translucent shade of its text color. Where an app doesn't report the caret position, a small mirror card shows the suggestion instead.
- **Knows the context.** With Screen Recording allowed, Tabber reads the text around the field on screen (the email you're replying to, the chat above) with on-device text recognition, so suggestions fit the conversation. Clipboard context and your own notes about how you write are optional.
- **Fixes typos and finds emoji.** After a misspelled word the suggestion becomes the fix (`recieve → receive`), and `:joy` or `:)` offer 😂 and 🙂. Tab applies either.
- **Other words on request.** Optionally, pausing at a suggestion shows a numbered list of other likely words; press the number to use one. Settings → Statistics shows words saved per day.
- **Stays out of the way.** It's off in password fields, terminals and code editors by default, holds back in tiny fields, and never owns Tab unless a suggestion is visible. Option-Tab always sends a real Tab.

## Status

Version 0.1. Verified live on macOS 27 in TextEdit, Safari, Chrome, Microsoft Word, Notes, Messages, Mail, Discord, Slack (web), Microsoft Teams, and the onboarding practice field; see [docs/compatibility.md](docs/compatibility.md) for exactly what was checked in each.

## Install

1. Download `Tabber.dmg` from [Releases](https://github.com/chriscorbell/tabber/releases) and drag Tabber to Applications.
2. Open it. Onboarding asks for Accessibility (to read the focused field and insert text), downloads a model (1–3.5 GB, picked for your Mac), and lets you try it.
3. Optional: allow Screen Recording for screen context.

Requires an Apple Silicon Mac with macOS 14 or later. 16 GB of memory is recommended for the default model.

## Shortcuts

| Action | Default |
|---|---|
| Accept the next word | Tab |
| Accept the whole suggestion | the key above Tab (`` ` `` / `§`) |
| Hide the suggestion | Esc |
| Send a real Tab | Option-Tab |
| Suggest here anyway | Control-`` ` `` |
| Pause in this app for 10 minutes | Control-Option-Command-`` ` `` |

All of them can be changed in Settings → Shortcuts.

## Models

Tabber runs base (pretrained, non-chat) models through [llama.cpp](https://github.com/ggml-org/llama.cpp) on the GPU. Base models continue text instead of answering it, which is exactly what autocomplete needs.

| Model | Download | Best for |
|---|---|---|
| Gemma 4 E2B | 3.4 GB | Default on Macs with 16 GB or more |
| Qwen3 1.7B Base | 1.1 GB | 8 GB Macs, lowest latency |
| Qwen3 4B Base | 2.5 GB | Highest quality, a little slower |
| Gemma 4 E4B | 5.3 GB | Pro/Max chips with 24 GB or more |
| Qwen3 0.6B Base | 0.4 GB | Tiny and very fast, noticeably weaker |

You can also drop any GGUF into `~/Library/Application Support/Tabber/Models`. Measured quality and latency are in [docs/benchmarks.md](docs/benchmarks.md).

## Privacy

- Inference, text recognition, and personalization all run locally. Tabber makes no network requests except downloading the model you pick from Hugging Face.
- It never reads password fields, and it masks things that look like secrets (keys, tokens, card numbers) before they reach the model.
- "Learn my writing" is off by default. When on, it keeps an encrypted history on this Mac (key in your Keychain) and uses it to favour your words and phrasing. Delete it any time in Settings.

## How it works

The short version: an event tap sees each key before the app does; Accessibility reads the focused field's text, caret position, and font; the session decides whether to suggest; llama.cpp continues the text before the caret, reusing its cache so each keystroke only evaluates the new characters; the overlay draws the rest of the word and the next few at the caret. Details are in [docs/architecture.md](docs/architecture.md).

## Build from source

```sh
brew install xcodegen
scripts/build-app.sh          # builds and signs build/Tabber.app
swift test                    # unit tests
```

`scripts/build-app.sh` signs with the identity configured in `project.yml`; set `TABBER_ADHOC=1` to sign ad hoc instead. `scripts/package-dmg.sh` makes a signed DMG, and `scripts/notarize.sh` produces a notarized, stapled app and DMG using the Apple ID signed into Xcode. `tabber-bench` measures suggestion quality and latency for any GGUF model; `tabber-probe` checks the Accessibility, keyboard, and overlay layers live.

## License

MIT. Models have their own licenses (Gemma Terms of Use, Apache 2.0 for Qwen).
