# Benchmarks

`tabber-bench simulate` replays the passages in `bench/passages.json` (24 passages: email, chat, docs, notes, posts, prompts; English, German, Spanish) as a user typing them. The simulated user reads the ghost text and presses Tab once per word while the next word matches what they meant to write; otherwise they type the next character, which advances the ghost when it still matches. Passages with a `screen` field get that text as screen context, the way OCR would provide it.

- **Saved**: 1 − keystrokes ÷ characters (Tab presses count as keystrokes).
- **First-word right**: share of shown suggestions whose first word was what the user meant.
- **Word precision**: accepted words ÷ shown words. Low precision means more ghost text the user reads and ignores.
- **Latency**: wall time per request, including prompt-cache reuse. "Eval tokens p50" is the median number of prompt tokens evaluated per request; 1 means the cache was reused for everything but the last token.

Machine: M5 Pro, 48 GB. llama.cpp b11577, Metal, all layers on GPU, one CPU thread. Medium length (2–4 words), word-start floor 0.3, first-word beam of 3 (candidates under 5% dropped outside the typed prefix, relative floor of 1e-10 inside it), repetition guard.

| Model (Q4_K_M) | Size | Saved | First word right | Word precision | p50 / p90 latency | Eval tokens p50 |
|---|---|---|---|---|---|---|
| Qwen3 0.6B Base | 0.4 GB | 50.1% | 41% | 24% | 25 / 33 ms | 1 |
| Qwen3 1.7B Base | 1.1 GB | 54.7% | 44% | 26% | 46 / 64 ms | 1 |
| Gemma 4 E2B | 3.4 GB | 54.5% | 45% | 29% | 71 / 108 ms | 1 |
| Qwen3 4B Base | 2.5 GB | 56.4% | 45% | 27% | 90 / 128 ms | 1 |
| Qwen3.5 2B Base (hybrid) | 1.3 GB | 52.7% | 41% | 26% | 67 / 86 ms | 52 |

Gemma 4 E2B is the default on Macs with 16 GB or more: about the same savings as Qwen3 1.7B but the highest word precision, so less ghost text to read and ignore. Qwen3 1.7B is the default below 16 GB.

Qwen3.5 is a hybrid recurrent model: its state can't be trimmed back to a common prefix, so every request re-evaluates the prompt tail, and the first-word beam is disabled for it.

## What moved the numbers (Qwen3 1.7B, before the candidate floors)

| Change | Saved | Word precision | p50 |
|---|---|---|---|
| No context preamble | 49.4% | 18% | 47 ms |
| Preamble with app, window, screen text (quoted style) | 53.5% | 21% | 46 ms |
| Bracketed `[Heading]` style instead | 53.3% | 25% | 48 ms |
| Reference text only, no labels | 51.5% | 23% | 45 ms |
| Word-start floor 0.12 → 0.3 | 53.5% | 21% → 25% | 46 → 42 ms |
| Short length (1–2 words) | 53.6% | 36% | 35 ms |
| Long length (4–7 words) | 53.6% | 13% | 69 ms |
| Suppress when first word < 10% likely | 53.1% | 25% | 46 ms |
| First-person framing ("I'm writing this on my Mac…") | 52.6% | 25% | 40 ms |

On Gemma 4 E2B the same comparison gives 54.1% for the quoted style, 53.5% first-person, 53.0% bracketed, 52.5% reference-only. Tabber keeps the quoted style.

Adding the candidate floors and a repetition guard then moved Qwen3 1.7B from 53.5% to 54.7% saved and first-word accuracy from 41% to 44%, and Gemma 4 E2B from 54.1% to 54.5% and 43% to 45%. One CPU thread instead of six made no latency difference, so Tabber uses one. A beam of 5 instead of 3 changed nothing (54.5% either way) and added a few milliseconds, so Tabber keeps 3.

Screen context is worth about four points. Longer suggestions don't save more keystrokes; they only add text to read, which is why the default stays at 2–4 words and stops early when the model hesitates.

Reproduce:

```sh
swift build -c release --product tabber-bench
.build/release/tabber-bench simulate --model ~/Library/Application\ Support/Tabber/Models/gemma-4-E2B.i1-Q4_K_M.gguf --floor 0.3
```
