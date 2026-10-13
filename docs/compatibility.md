# App compatibility

What has been checked live on macOS 27 (M5 Pro) with the Release build. "Ghost" means the suggestion was drawn inline at the caret; "Tab" means accepting inserted exactly the shown text (read back from the field, or from a screenshot where the app doesn't expose its text).

| App | Field | Ghost | Font | Tab / whole accept | Screen context | Notes |
|---|---|---|---|---|---|---|
| TextEdit | document | yes | host font (Menlo, Helvetica, Georgia, Avenir checked) | yes / yes | – | type-through, follow-up after accept-all, autocorrect and emoji replacements verified |
| Safari | textarea | yes | Georgia | yes | yes ("Lisbon offsite by Thursday.") | |
| Safari | contenteditable | – | – | field read and insertion verified by the module tests | – | |
| Chrome | textarea | yes | Georgia, inferred from word positions (Chrome reports size only) | yes | yes | needs Chrome's accessibility tree, which Tabber turns on |
| Chrome | contenteditable | – | – | field read and insertion verified by the module tests | – | |
| Electron (test app) | contenteditable composer | yes | system font | yes | yes ("release on Friday.") | stands in for Slack, Discord, Notion, Teams, which need logins |
| Microsoft Word | document | yes | Aptos (Body) | yes | – | led to the placeholder filter ("[Job Title]" is now cut) |
| Notes | note body (iCloud) | yes | host font | yes | – | |
| Messages | new message | yes | – | yes | – | Tabber also suggested in the "To:" field; recipient and search fields are now excluded |
| Mail | compose body | yes | Helvetica | shown and accepted; body text isn't exposed to AX for read-back | – | address fields (`Mail.toField`, `ccField`, …) are excluded |
| Tabber onboarding | practice field | yes | system | yes | – | |
| TextEdit | word alternatives (after a 2 s pause) | yes | – | digit picks (2 → " new") | – | list shows other words for the suggested slot |

Off by default: terminals, code editors (Xcode, VS Code, Cursor, Zed, JetBrains), password managers. Enable them per app in Settings → Apps & Websites.

Known gaps:
- Apps that draw text themselves without exposing it to Accessibility (Google Docs without screen-reader mode, Figma, games, remote desktops) can't get suggestions.
- Mail's compose body doesn't report its text to Accessibility for read-back, so Tab acceptance there was confirmed on screen only.
- Untested here: Slack, Discord and Teams with real accounts (the Electron test app covers their text fields), Pages, Firefox (expected to need the mirror card).
