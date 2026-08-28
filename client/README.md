# Sloppa

Native Flutter frontend for the Sloppa monorepo. The backend lives at the repository root and the Flutter client lives under `client/`. ChatGPT cookies/browser tokens remain server-side, bridge credentials use OS secure storage, and cached conversations are AES-256-GCM encrypted.

```bash
cd client
flutter create --platforms=android,linux,windows,macos,ios --project-name sloppa .
flutter pub get
flutter analyze
flutter test
```

CI generates the Android runner, grants network/microphone permissions, runs format/analyze/tests, and builds a debug APK. Non-loopback bridge URLs must use HTTPS; bridge bearer credentials are never sent to direct ChatGPT/CDN asset URLs.

Sloppa covers normal ChatGPT Chat: history/search, rich streaming, models/reasoning, Search/Create image/Deep Research/Study, apps, Temporary Chat, uploads/Library, generated assets/citations/code/tool blocks, message actions/branches/feedback, pins/share/archive/delete, Projects, GPTs, Memory, Deep Research interactions, and native WebRTC Voice. Canvas is intentionally omitted because the bridge reports it as deprecated.
