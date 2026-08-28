# Flutter client

Native Flutter frontend for the subscription-backed ChatGPT bridge in this repository.

The app talks only to your own ChatGPT-Web2API server. It never receives or stores ChatGPT cookies, browser tokens, or an OpenAI API key. The bridge URL and optional bridge API key are stored with `flutter_secure_storage`; cached conversation data is AES-256-GCM encrypted with a device-local key kept in secure storage.

## Bootstrap

```bash
cd client
flutter create --platforms=android,linux,windows,macos,ios --project-name chatgpt_bridge_client .
flutter pub get
flutter analyze
flutter test
```

CI generates the Android runner, injects `INTERNET` and `RECORD_AUDIO`, runs formatting, analysis and tests, then builds a debug APK.

For Android Voice, ensure the generated manifest contains `android.permission.INTERNET` and `android.permission.RECORD_AUDIO`. For iOS/macOS Voice, add `NSMicrophoneUsageDescription` before distribution.

## Connection

Loopback HTTP (`http://127.0.0.1:8080`) is allowed. Non-loopback bridge URLs must use HTTPS. If the bridge has `api_keys` configured, enter one in Settings; it is sent to the bridge only. Direct ChatGPT/CDN asset URLs never receive the bridge Bearer token.

## Current surface

The client implements conversation history/search, encrypted snapshots, rich SSE/background updates, models/reasoning, Search/Create image/Deep Research/Study, dynamic apps, Temporary Chat, uploads/Library, generated images/files/citations/code/tool blocks, message actions/branches/feedback, pins/share/archive/delete, Projects, custom GPTs, Memory, Deep Research interactions, and native WebRTC Voice.

Canvas is intentionally omitted because the current ChatGPT experience uses normal writing/code blocks and the backend reports Canvas as deprecated.
