# MusicTube production checklist

The repository is hardened for release builds, but these external approvals and operator actions cannot be completed in source control.

## Required before distribution

- Revoke and rotate every credential that has appeared in the repository or local review artifacts. Restrict the replacement YouTube API key to the production bundle and the APIs it needs.
- Audit and, if necessary, purge exposed credentials from Git history before making the repository public.
- Obtain explicit written authorization for every third-party streaming or offline-download capability. Without that authorization, remove stream extraction and downloading before App Store submission.
- Deploy `server.js` behind HTTPS, set `OPENROUTER_API_KEY` only in the server environment, add edge rate limiting or App Attest validation, and set `MUSICTUBE_AI_ENDPOINT` to its `/api/curate` URL. Leave the value empty to ship without AI curation.
- Add the CarPlay audio entitlement only after Apple grants it for the production App ID.
- Complete App Store Connect privacy labels so they agree with `PrivacyInfo.xcprivacy` and `PRIVACY_POLICY.html`.
- Complete the current App Store age-rating questionnaire and supply a review account or documented guest-mode review path.

## Release verification

- Run unit tests and a Release build with the current required Xcode and iOS SDK.
- Test sign-in, token refresh, guest mode, search cancellation, playback recovery, background audio, downloads, deep links, share extension, App Intents, and data deletion on physical devices.
- Test VoiceOver, Dynamic Type, Reduce Motion, Low Power Mode, cellular restrictions, airplane mode, and low-storage behavior.
- Capture SwiftUI, Time Profiler, Energy Log, and memory traces for Home scrolling, Search typing, player presentation, and a long playback session.
- Archive and inspect the privacy report, entitlements, embedded extension versions, and exported IPA before upload.
