# Flutter client

Native Flutter frontend for the subscription-backed ChatGPT bridge in this repository.

The app talks only to your own ChatGPT-Web2API server. It never receives or stores ChatGPT cookies, browser tokens, or an OpenAI API key. The bridge URL and optional bridge API key are stored with `flutter_secure_storage`; cached conversation data is AES-256-GCM encrypted with a device-local key kept in secure storage.

## Bootstrap

The durable Flutter application source lives here. Platform runners are generated from Flutter's current stable templates rather than vendored stale Gradle/Xcode boilerplate:

```bash
cd client
flutter create --platforms=android,linux,windows,macos,ios --project-name chatgpt_bridge_client .
flutter pub get
flutter analyze
flutter test
```

CI performs the Android bootstrap on every change, injects `INTERNET` and `RECORD_AUDIO`, runs analysis/tests, and builds a debug APK. This deliberately validates against the current Flutter Android template instead of freezing an old Gradle wrapper in the repository.

For a generated Android runner, ensure `android/app/src/main/AndroidManifest.xml` contains:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

For iOS/macOS Voice, add an appropriate microphone usage description (`NSMicrophoneUsageDescription`) to the generated platform plist before distribution.

## Connection

For a server on the same device, `http://127.0.0.1:8080` is allowed. Non-loopback bridge URLs must use HTTPS. If the bridge has `api_keys` configured, enter one in Settings; it is sent as a Bearer token to the bridge only. Direct ChatGPT/CDN asset URLs never receive the bridge Bearer token.

## Current surface

The Flutter client covers the normal consumer ChatGPT Chat workflow exposed by the bridge:

- full paged conversation list and search
- encrypted offline conversation snapshots
- rich SSE streaming and resumable background updates
- models and reasoning levels
- Search, Create image, Deep Research and Study modes
- dynamically discovered app/plugin selection
- Temporary Chat
- local file/image upload and Add from Library
- generated image display and authenticated file download
- citations, code, execution output, quotes, tool/research status and editable writing/code blocks
- stop generation, copy, edit, regenerate, branch-in-new-chat and alternate response navigation
- thumbs-up/down feedback
- pin/unpin, share/revoke, rename, archive and delete
- Projects: list, create, instructions, conversations, files/download and delete
- custom GPT list/start-chat
- Memory list/create/delete
- Deep Research interactive plan/action controls and reports
- native WebRTC Voice with local microphone/audio, voice selection, mute/end and conversation/project context

Canvas is intentionally not exposed: current ChatGPT uses normal writing/code blocks and the backend privacy/capability layer reports Canvas as deprecated.
