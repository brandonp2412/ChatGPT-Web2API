# Flutter client

Native Flutter frontend for the subscription-backed ChatGPT bridge in this repository. It talks only to your own bridge: ChatGPT cookies/browser tokens stay server-side, bridge credentials use OS secure storage, and cached conversations are AES-256-GCM encrypted.

## Bootstrap

```bash
cd client
flutter create --platforms=android,linux,windows,macos,ios --project-name chatgpt_bridge_client .
flutter pub get
flutter analyze
flutter test
```

CI generates the Android runner, injects `INTERNET` and `RECORD_AUDIO`, runs format/analyze/tests, and builds a debug APK. For iOS/macOS Voice, add `NSMicrophoneUsageDescription` before distribution.

Loopback HTTP is allowed; non-loopback bridge URLs must use HTTPS. Direct ChatGPT/CDN asset URLs never receive the bridge Bearer token.

The client covers history/search, encrypted snapshots, rich streaming/background updates, models/reasoning, Search/Create image/Deep Research/Study, apps, Temporary Chat, uploads/Library, generated assets/citations/code/tool blocks, message actions/branches/feedback, pins/share/archive/delete, Projects, GPTs, Memory, Deep Research interactions, and native WebRTC Voice. Canvas is intentionally omitted because the backend reports it as deprecated.
