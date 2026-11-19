# Research notes (November 2026)

How the design was chosen. Snapshot as of T3 Code 0.1.9–0.1.11-nightly and iOS 26.5 / 27.2.

## T3 Code: ways in

| Surface | Auth | Can create/send? | Stability |
|---|---|---|---|
| **MCP `POST /mcp`** (chosen) | MCP OAuth 2.1 + PKCE, approved with a `t3 pair` code; 30-day bearer, `/mcp` only, orchestration scopes | Yes: `t3_thread_launch/send/wait/read/organize/...` | The tool interface was unchanged for our tools from 0.1.9 to main; T3's own `t3 thread` CLI uses it |
| WebSocket `/ws` (official apps) | Bearer or DPoP token from `POST /oauth/token`, `wsTicket` | Yes: Effect RPC `orchestration.dispatchCommand` | `orchestrationProtocol=2` is a hard gate (426 on mismatch); large, fast-moving command union |
| REST `/api/orchestration/*` | Same as WS + `x-t3-orchestration-protocol: 2` | Read-only | — |
| Webhooks `/api/hooks/:id/:token` | Hook secret | Triggers a pre-made scheduled task, no reply | — |

Pairing details that matter:
- `t3 pair` codes are 12 chars, valid 5 minutes, single use. Pairing URL: `http(s)://host[:port]/pair#token=CODE`; app link `t3code://pair?pairingUrl=…`.
- MCP OAuth: `POST /oauth/mcp/register` → `POST /oauth/mcp/decision {authorization, decision:{_tag:"pairing-code", access:"auto"|"approval-required", code}}` returns `{redirectTo}` with the auth code → `POST /oauth/mcp/token`. Redirect URIs must be https or loopback, so we use a loopback URI that's never actually loaded.
- `privateNetworkOnly` servers drop any connection that isn't private **IPv4** on both ends. Tailscale IPv6 is refused; `tailscale serve` (`t3 pair --tailscale`) works because it proxies from loopback.
- MCP tokens can't be refreshed (only the `authorization_code` grant): re-pair every 30 days.
- T3 Connect (the hosted relay) requires Clerk sign-in and only allows the `t3-mobile`/`t3-web` client ids, so it isn't usable by a third-party app.
- The official app has no App Intents or Siri support (only quick actions, widgets, a Live Activity, and a share extension).

Turn completion: loop `t3_thread_wait {timeoutMs}` until `timedOut:false`, then read the `messages` view and take the last `assistant_message` for that `runId` (newer servers mark `phase:"final_answer"`). A status of `waiting` means it's blocked on an approval or question.

## Siri and Apple Intelligence

- **There's no third-party "brain" slot in Siri.** ChatGPT is the only documented extension model. The rumored iOS 27 "Extensions" (Claude/Gemini) were found in beta code but are server-disabled and aimed at partners. In Japan only (iOS 26.2+), `@AppIntent(schema: .assistant.activate)` plus a side-button entitlement lets a voice app take over the side button.
- **App Shortcut phrases can't contain a `String`** (only `AppEntity`/`AppEnum`). So "Tell Tea Three" plus a `requestValueDialog` follow-up is the standard pattern. iOS 27.3's Siri AI developer preview adds `@AppIntent(.tool)`, which lets Siri fill free text from one sentence, but adding any tool intent disables App Shortcut phrases in Siri, and it needs the iOS 27 SDK.
- Intents get about 30 s, and Siri may cut them shorter. `supportedModes` (iOS 26) replaces `openAppWhenRun`. Foreground modes require unlocking, so background intents are the ones that work while driving.
- iOS 27 `LongRunningIntent` + `performBackgroundTask` can run past 30 s with a system Live Activity, if they report progress.
- Siri's free-text follow-up sometimes answers a question itself instead of passing it to the app (an open forum issue since iOS 18). Fire-and-forget statements ("log a burrito") aren't affected.

## CarPlay

- iOS **26.4** added the voice-based conversational category, entitlement `com.apple.developer.carplay-voice-based-conversation`.
  - Allowed templates: voice control, list, grid, tab bar, information, alert, action sheet (and search in iOS 27). Max template depth is 3.
  - Rules: voice must be the primary interface from launch; hold the audio session only while in use; **don't show text or images in response to queries**; the voice template must be visible while the mic is live.
  - `CPVoiceControlState.actionButtons` (iOS 26.4) gives you up to the template's `maximumActionButtonCount` buttons.
- These apps can't become the system assistant: there's no wake word and no steering-wheel button. Siri in CarPlay still runs App Intents, which is why Siri is the zero-entitlement path.
- Getting it: request at developer.apple.com/contact/carplay (paid account); approval takes days to weeks. Home Assistant and Conduit (open source) got it.
- Audio: `.playAndRecord`, default mode, no mixing per Apple. Home Assistant also uses `.voiceChat` while listening. Keychain items must be readable after first unlock.

## Sources

- T3 Code source: <https://github.com/pingdotgg/t3code> (`apps/server/src/mcp`, `apps/server/src/auth`, `packages/contracts`, `apps/server/src/cli/thread.ts`)
- CarPlay Developer Guide (Oct 2026): <https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf>
- Entitlement: <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-voice-based-conversation>
- `CPVoiceControlTemplate`: <https://developer.apple.com/documentation/carplay/cpvoicecontroltemplate>
- WWDC26 CarPlay (212), App Intents (343, 345): <https://developer.apple.com/videos/wwdc2026/>
- Siri AI developer preview: <https://developer.apple.com/news/?id=gdk2umrf>
- Side-button voice apps (Japan): <https://developer.apple.com/documentation/appintents/launching-your-voice-based-conversational-app-from-the-side-button-of-iphone>
- App Shortcut phrase parameter limits: <https://developer.apple.com/forums/thread/779109>
- Home Assistant CarPlay Assist: <https://github.com/home-assistant/iOS> (`Sources/CarPlay/Templates/QuickAccess/CarPlayAssistSession.swift`)
- Conduit CarPlay: <https://github.com/cogwheel0/conduit>
