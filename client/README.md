# Flutter client

Native Flutter frontend for the subscription-backed ChatGPT bridge in this repository.

The app talks only to your own ChatGPT-Web2API server. It never receives or stores ChatGPT cookies, browser tokens, or an OpenAI API key. The bridge URL and optional bridge API key are stored with `flutter_secure_storage`; cached conversation data is AES-256-GCM encrypted with a device-local key kept in secure storage.

## Bootstrap

The durable Dart source lives here even before platform wrappers are generated. On a machine with Flutter installed:

```bash
cd client
flutter create --platforms=android,linux,windows,macos,ios .
flutter pub get
flutter analyze
flutter test
```

`flutter create` preserves `lib/`, `pubspec.yaml`, and `analysis_options.yaml` while creating platform runner directories.

## Connection

For a server on the same device, `http://127.0.0.1:8080` is allowed. Non-loopback bridge URLs must use HTTPS. If the bridge has `api_keys` configured, enter one in Settings; it is sent as a Bearer token to the bridge only.

## Voice platform permissions

Voice terminates WebRTC in Flutter. Only the SDP offer/answer goes through the bridge; ChatGPT browser credentials never enter the client.

After generating the platform wrappers, add the normal microphone permissions required by `flutter_webrtc`:

- Android: keep `minSdk` at 23 or newer and add `android.permission.RECORD_AUDIO`. Add the Android Bluetooth permissions when headset routing is required on the targeted Android versions.
- iOS: add `NSMicrophoneUsageDescription` to `ios/Runner/Info.plist`.
- macOS: add a microphone usage description and enable the audio-input entitlement for the Runner target.
- Linux/Windows: microphone access is handled by the OS/runtime; package the platform WebRTC dependencies produced by the Flutter plugin build.

The client negotiates Voice against `/v1/voice/session`, captures microphone audio locally, renders the remote audio track locally, supports mute/end, and keeps the active conversation/project context fixed for the duration of the modal voice session.

## Current client surface

The current client includes conversation history/search, Projects and project chats, custom GPT selection, rich Markdown/citations, encrypted offline snapshots, SSE streaming and background updates, regenerated-response paging, edit/regenerate/branch actions, model/reasoning/tool controls, Temporary Chat, uploads, Add from Library, Deep Research intermediate actions/reports, stop generation, and native WebRTC Voice.
