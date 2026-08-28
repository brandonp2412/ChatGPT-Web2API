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

Current client surfaces include conversation history, rich conversation rendering, SSE streaming, background conversation events, model/reasoning/tool controls, file attachments, stop generation, regenerated-response branch selection, citations, and encrypted offline snapshots.
