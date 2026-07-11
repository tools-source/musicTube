# MusicTube architecture and performance audit

Baseline (2026-07-10): the Debug iOS Simulator build succeeds for `MusicTube`, the share extension, CarPlay-linked sources, and App Intents metadata extraction. The deployment target is iOS 17.0. The checked-in project file has pre-existing version-number edits that are not part of this cleanup. Baseline screen sizes were Root 1,247, Home 1,297, Search 1,246, Library 2,101, Player 1,240, and Downloads 903 lines; `AppState` was 4,955 lines with 43 published properties.

## Files requiring refactoring

- `MusicTube/App/AppState.swift` (4,947 lines): authentication, lifecycle, Home, search, playback orchestration, library mutation, recommendations, persistence, deep links, recognition, downloads, and CarPlay invalidation.
- `MusicTube/Services/PlaybackService.swift` (2,402): AVPlayer ownership, queueing, restoration, prefetching, buffering, and remote-control integration.
- `MusicTube/Services/DownloadService.swift` (1,577): background URLSession ownership, queueing, persistence, folders, restoration, file work, and UI snapshots.
- `MusicTube/Services/YouTubeAPIService.swift` (2,854): transport, parsing, authentication fallbacks, metadata, and catalog endpoints.
- `MusicTube/CarPlay/CarPlayManager.swift` (1,420): templates, presentation models, artwork, search, and playback actions.
- `RootView.swift`, `HomeView.swift`, `SearchView.swift`, `LibraryView.swift`, `PlayerView.swift`, and `DownloadsView.swift`: large screen trees with broad `AppState` observation and render-time derived collections.

## Main performance findings

1. `AppState` is `@MainActor` and exposes more than 40 published properties. Every major screen observes it, so unrelated account, download, recommendation, and playback changes invalidate broad view trees.
2. The original cold launch overlaid an animated experience on every process start. The implementation now shows the real shell immediately after first launch and restores cached/local state without waiting for remote authentication or recommendations.
3. Recommendation filtering, scoring, deduplication, language/context classification, and sorting run in `AppState` on the main actor.
4. Major views repeatedly filter/sort tracks and create `Array(collection.enumerated())` inside rendering paths.
5. Search query, result, suggestion, pagination, debounce, cancellation, cache, and stale-response state have now moved into a focused `SearchViewModel`; the compatibility facade remains for CarPlay and intent callers.
6. Artwork already has memory/disk caches, downsampling, and in-flight deduplication. It lacks target-size semantics, bounded request concurrency, and a short negative cache for repeatedly failing URLs.
7. Downloads use actor-isolated disk persistence, background restoration, thresholded progress publication, adaptive network/power/thermal/lifecycle limits, and a focused `DownloadViewModel`/`DownloadSnapshot` that prevents download callbacks from invalidating the app shell.
8. Home cache writes are debounced and disk work is detached, but several other profile/default mutations remain synchronous on the main actor.

## Redundant or unused candidates

- `LaunchExperienceView` is legacy for repeat cold launches; it remains useful for first launch/onboarding and must not be deleted yet.
- `AppState.MainTab.settings` is a fifth tab even though the desired shell has four primary tabs. Settings is indirectly used and should be routed from profile/library before removal.
- Several duplicate artwork/track presentation patterns and computed view fragments exist across Home, Library, Search, Downloads, and CarPlay. They are candidates for consolidation only after call-site and indirect-system verification.
- Debug logging remains in hot download/playback paths. It uses the structured logger abstraction, but frequency and privacy should be tightened.

No type, selector, asset, persistence model, or extension is proven safe to delete in this phase. CarPlay, App Intents, URLSession delegates, notification callbacks, Codable compatibility, and Objective-C entry points are treated as indirect references.

## Proposed architecture

- Keep `AppState` as a compatibility facade during incremental migration so CarPlay, intents, and existing views continue to work.
- Introduce an `AppCoordinator` for lifecycle, routing, deep links, and cross-feature events.
- Move feature state behind focused authentication, Home, search, library, player, download, playlist, and settings models. Views should observe only their feature model or small value snapshots.
- Move pure/stateful background work to actors: `RecommendationEngine`, search normalization/cache, download coordination/persistence, playback queue preparation, and persistence encoding/file I/O.
- Keep AVFoundation, MediaPlayer, CarPlay UI, UIKit delegates, and UI-facing publication on their required actor/queue.
- Adopt small Equatable/Sendable screen snapshots and stable presentation identities.

## Implementation order

1. Remove launch/auth UI gating while preserving eager restoration and first-launch animation.
2. Extract and test recommendation filtering/ranking behind an actor, then migrate scoring in safe slices.
3. Preserve the existing search task lifecycle while moving query normalization/cache policy behind an isolated service.
4. Improve artwork target sizing, failure caching, and request limits.
5. Narrow download/player observation and extract screen snapshots.
6. Decompose major views and centralize lightweight design tokens.
7. Remove only code proven unused, then validate app, tests, CarPlay compilation, App Intents extraction, and persistence compatibility.

## Compatibility constraints

- Preserve all existing UserDefaults keys, local profile encodings, download JSON shapes, filenames, track identifiers, playlist IDs, and the background URLSession identifier `com.musictube.downloads.background`.
- Preserve `AppContainer` until CarPlay and App Intents have a replacement runtime handoff.
- Preserve AppDelegate background-session completion handling and all URLSession/CarPlay/notification Objective-C delegate signatures.
- Preserve PlaybackService ownership of AVPlayer/audio-session work and RemoteCommandManager ownership of MPRemoteCommandCenter/Now Playing state.
- Preserve Codable defaults for older `Track`, download, folder, profile, and authentication data.
