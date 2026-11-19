<img src="assets/icon.svg" width="64" height="64" alt="">

# Tea Three

**Talk to [T3 Code](https://t3.codes) from Siri, the Action button, and CarPlay.**

Tea Three is a tiny native iOS app that turns your voice into messages for one
pinned **Copilot** thread on your own T3 Code server. The Copilot is a normal T3
agent with T3's built-in thread tools, so *it* decides where things go: it
continues the right thread, starts a new one in the right project, checks on
running work, and settles one-off threads when they're done.

It's separate from the official T3 Code app (different bundle id, no shared
state), so if T3 changes something and Tea Three breaks, your main app keeps working.

```
 "Hey Siri, tell Tea Three"           Action button / CarPlay
        │  (fire and forget)                 │  (hands-free conversation)
        ▼                                    ▼
 ┌──────────────────────── Tea Three (iPhone) ────────────────────────┐
 │  SendToT3Intent ──► "Sent."      VoiceSession: listen → send →     │
 │                                  wait → speak → listen…            │
 └───────────────┬────────────────────────────────────────────────────┘
                 │  MCP over HTTPS/HTTP  (POST /mcp, OAuth bearer token
                 │  scoped to orchestration only)
                 ▼
 ┌──────────────── T3 Code server on your Mac ────────────────────────┐
 │  📌 "Tea Three Copilot" thread  ──t3_thread_search/send/launch──►  │
 │                                    your other threads & projects   │
 └────────────────────────────────────────────────────────────────────┘
```

## What you can do

| Where | How | What happens |
|---|---|---|
| Anywhere | **"Hey Siri, tell Tea Three"** → Siri asks "What should I send?" → talk | Siri says **"Sent."** and you're done. The Copilot handles it. If the server can't be reached, it's saved and sent the next time the app runs. |
| Action button | Assign the **Talk to T3** shortcut | Opens straight into hands-free mode. Talk, hear the answer in Tea Three's voice (not Siri's), keep talking. Say "goodbye" to stop. |
| CarPlay | Open Tea Three on the car screen | Same hands-free loop with CarPlay's voice template. Needs Apple's entitlement (see below). |
| Shortcuts | **Ask T3 Code** action | Returns the Copilot's answer as text (≈25 s max) so you can chain it. |
| In the app | Type or tap the mic | Same Copilot, with a transcript. |

The Copilot is told how each message arrived (Siri, so nobody's listening;
voice, so keep it short and speakable; typed) and to never settle its own thread.
The Copilot thread is a normal pinned thread in T3 Code, so you see it (and its
history) in the regular T3 app. It lives in your broadest project (usually the home
folder) unless you pick one in Settings. The app itself only shows the latest exchange.

Add your own standing instructions in **Settings › Notes for the Copilot**, for example:

> Food logs go to the Health project with the food-log skill. Anything I say to "do later" gets snoozed until 9am tomorrow.

## Setup

1. **Reach your Mac from the phone.** Easiest: [Tailscale](https://tailscale.com)
   on both, then `t3 pair --tailscale` (gives an `https://<mac>.<tailnet>.ts.net`
   address). Plain LAN or tailnet IPs (`http://100.x.y.z:3773`) also work. T3's
   private-network mode only accepts **IPv4** private addresses, so use the 100.x
   address, not the IPv6 one.
2. **Build and install.**
   ```sh
   brew install xcodegen
   cp Config/Local.example.xcconfig Config/Local.xcconfig   # set TEA_THREE_TEAM
   xcodegen generate && open TeaThree.xcodeproj
   ```
   Run on your iPhone. A free Apple ID works, but the app expires after 7 days.
   A paid account lasts a year and is needed for CarPlay.
3. **Pair.** On the Mac, run `t3 pair` and scan the QR code in Tea Three (or paste the URL).
4. **Pick a model** on the main screen. The list comes from your server, and Tea
   Three never picks one for you. The Copilot uses it, and threads it starts inherit
   it. Changing it switches the Copilot thread right away.
5. **Action button:** Settings › Action Button › Shortcut › Tea Three › *Talk to T3*.

**Skip pairing on the phone (Gala builds).** `ios-build.sh` bakes a credential
into the app if one exists at `~/.config/tea-three/bootstrap.json` (or
`$TEA_THREE_BOOTSTRAP`). Pair from the Mac once, then build:

```sh
TEA_THREE_CREDENTIAL=~/.config/tea-three/bootstrap.json \
  swift run --package-path Packages/TeaThreeKit tea-three pair 'http://<server>:3773/pair#token=…'
gala deliver
```

The app adopts each baked token once on first launch, so unpairing or pairing by
hand sticks. The token is in the IPA, so only share the build with yourself.

The token lasts 30 days (T3's limit for MCP clients, with no refresh). When it
expires, Siri tells you to open the app, and you run `t3 pair` again.

## How it talks to T3 Code

Tea Three uses T3 Code's **MCP endpoint** (`POST /mcp`), the same tool surface
T3's own agents use, instead of the official app's private WebSocket protocol:

- **Auth:** T3's own OAuth 2.1 (dynamic client registration + PKCE), approved
  with a `t3 pair` code instead of a browser. The token is scoped to
  `orchestration:read` and `orchestration:operate` and is rejected everywhere
  except `/mcp`. It's stored in the Keychain as *after first unlock*, so Siri and
  CarPlay work while the phone is locked. You can revoke it from T3's connections
  list.
- **Tools used:** `t3_thread_send`, `t3_thread_launch`, `t3_thread_search`,
  `t3_thread_read`, `t3_thread_wait`, `t3_thread_organize`, `t3_thread_list`,
  `t3_thread_configure`, `t3_thread_interrupt`, `t3_project_list`, `orchestrator_capabilities`.
- **Why MCP:** it's a public, documented surface that T3's own CLI (`t3 thread`)
  is built on. It's versioned by the MCP spec, has idempotent `clientRequestId`
  retries, and doesn't depend on the orchestration WebSocket protocol number,
  which hard-fails (HTTP 426) on bumps.

## Contract testing

T3 Code ships nightly, so Tea Three checks its assumptions instead of trusting them:

- **`ToolContract`** (`Packages/TeaThreeKit/Sources/TeaThreeKit/T3/ToolContract.swift`)
  lists every tool, argument, and enum value Tea Three sends. `ToolContract.check`
  diffs that against a server's live `tools/list` schemas. It reports
  **breaking** problems (a tool, argument, or enum value is gone, or there's a new
  required argument) and **degraded** ones (a nice-to-have tool is gone).
- **Recorded fixtures** (`Tests/TeaThreeKitTests/Fixtures/v0.1.9`): real responses
  from T3 Code 0.1.9. The unit tests decode them and run the whole Copilot flow
  against a fake server built from them.
- **Live contract tests** (`Tests/LiveContractTests`): pair, check the contract,
  then launch → search → list → pin → read → wait → archive a thread. No model
  ever runs, so they work on a fresh server with no provider logins.
- **Nightly CI** boots `t3@latest` and `t3@nightly` from npm, runs the live tests,
  and opens an issue if upstream breaks the contract.
- **In the app:** Settings › *Check compatibility* runs the same check against your server.

```sh
cd Packages/TeaThreeKit && swift test                 # unit + fixture contract
scripts/contract-against-npm.sh nightly               # live, against t3@nightly
swift run tea-three pair 'http://127.0.0.1:3773/pair#token=…'
swift run tea-three contract                          # against your own server
swift run tea-three ask "what's running right now?"   # same path as voice mode
swift run tea-three record Tests/TeaThreeKitTests/Fixtures/v0.1.10   # new fixtures
```

Verified so far: T3 Code **0.1.9** (fixtures and live) and **0.1.11-nightly.20261118** (live).

## CarPlay

iOS 26.4 added a CarPlay category for **voice-based conversational apps**
(`com.apple.developer.carplay-voice-based-conversation`). ChatGPT and Home
Assistant use it. Tea Three ships the scene (`App/Sources/CarPlay`): a
`CPVoiceControlTemplate` that starts listening when opened, with
listening/thinking/speaking states and Start/Stop buttons. Apple's rules for
this category forbid showing text replies on screen, so replies are only spoken.

It stays dark until Apple grants the entitlement:

1. Request it at <https://developer.apple.com/contact/carplay/> (paid developer account).
2. Enable it on the App ID, make a new provisioning profile.
3. In `Config/Local.xcconfig`: `TEA_THREE_ENTITLEMENTS = App/TeaThree-CarPlay.entitlements`.

Until then, "Hey Siri, tell Tea Three…" works in the car with no entitlement.

## Known limits and what's next

- **Siri can't take the message in one breath.** App Shortcut phrases can't
  contain free-form text, so Siri asks a follow-up question. iOS 27.3's Siri AI
  tool intents (`@AppIntent(.tool)`) remove that, but need the iOS 27 SDK.
- **No third-party app can replace Siri's brain** (the ChatGPT-style
  integration). Outside Japan there's no side-button hook for other assistants.
- **Long jobs:** Siri drops are fire-and-forget by design. Voice mode waits as
  long as it takes. Shortcuts' *Ask* gives up after about 25 s. iOS 27's
  `LongRunningIntent` would allow longer waits.
- **Approvals:** if a thread stops for an approval, voice mode says so, and you
  approve it in T3 Code. Pair with *Run without asking* for hands-free use.

See [docs/RESEARCH.md](docs/RESEARCH.md) for the investigation behind these choices.

## Layout

```
App/                       iOS app (SwiftUI, App Intents, CarPlay scene)
Packages/TeaThreeKit/      client library + `tea-three` CLI + tests
  Sources/TeaThreeKit/     MCP client, OAuth pairing, T3 tools, Copilot, contract
  Tests/                   fixture tests, live contract tests
scripts/                   contract-against-npm.sh
ios-build.sh, ios-test.sh  Gala Engine recipes (build + bundled login, kit tests)
project.yml                XcodeGen spec (the .xcodeproj is generated, not committed)
```

Not affiliated with T3 Tools or Apple. MIT licensed.
