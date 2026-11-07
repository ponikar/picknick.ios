# Picknick — Private On-Device Photo Index

Status: architecture draft, 2026-09-12
Scope of this document: the local indexer and search engine. The "remote LLM asks for context" feature is out of scope, but the boundary for it is reserved (see §9).

## 1. Goal and non-negotiables

- Index (almost) every photo on the iPhone so it can be remembered and searched by meaning, text, place, time and people-count.
- Everything stays on device. The indexer target has no network entitlement and makes no network calls. Ever.
- Ready-to-use: index is warm after one initial pass, then stays in sync automatically without the user thinking about it.
- Works on all iOS 18+ iPhones; gets smarter on Apple Intelligence devices.

## 2. Capability tiers

| Tier | Devices | What we use |
|---|---|---|
| Baseline | iOS 18+, any chip | PhotoKit, Vision (Swift API), Core ML (bundled MobileCLIP), NaturalLanguage |
| Enhanced | iOS 26+, Apple Intelligence on (A17 Pro / M-series and later) | + Foundation Models on-device LLM for captions, entity extraction, query parsing |

Everything in the Baseline tier is mandatory for search to work. The Enhanced tier only improves ranking and query understanding; it is never required. Gate with `SystemLanguageModel.default.availability`.

Note: the user-facing term "ImageKit" here means Apple's image analysis stack: the Vision framework (programmatic) and VisionKit's `ImageAnalyzer` (Live Text UI). We use Vision for indexing; VisionKit only for the viewer UI. Visual Look Up results are not exposed programmatically, so we can't index them.

## 3. System overview

```
PhotoKit ──► PhotoSource ──► IndexScheduler ──► Extractors ──► IndexStore (SQLite)
   ▲             │                 │                                   │
   │       change tokens      job queue,                               ▼
   │             │           bg tasks, policy                     SearchEngine
   └─────────────┘                                                     │
                                                                       ▼
                                                              App UI / ContextBroker (future)
```

Swift Package modules (one target each, no cross-talk except through protocols):

- `PhotoSource` — PhotoKit adapter: enumeration, persistent change tracking, thumbnail loading, limited-library handling.
- `Extractors` — `FeatureExtractor` implementations, each with a stable `id` and integer `version`.
- `IndexStore` — SQLite via GRDB: schema, migrations, vector cache, FTS.
- `IndexScheduler` — job queue, priorities, BackgroundTasks integration, thermal/battery policy.
- `SearchEngine` — query parsing, hybrid retrieval, rank fusion.
- `ContextBroker` — future: builds text-only, user-approved context bundles for a remote LLM. Only module allowed to talk to the app's network layer.
- `PicknickApp` — SwiftUI.

## 4. Decisions (ADR log)

### D1. Enumerate and resync via PhotoKit persistent change history, never full walks

Use `PHPhotoLibrary.shared().currentChangeToken` and `fetchPersistentChanges(since:)` (iOS 16+). After each committed batch, persist the token in `sync_state`. On every wake (foreground, background task, change observer), fetch changes since the stored token and enqueue inserted/updated ids, delete removed ids.

Fallback: if PhotoKit throws `persistentChangeTokenExpired` or `persistentChangeDetailsUnavailable` (history got pruned, first run, restore from backup), run a **reconciliation pass**: fetch all `PHAsset` ids + `modificationDate` in one `PHFetchResult` (cheap, ids only), diff against the `assets` table, enqueue the delta, store the new token.

Foreground: also register a `PHPhotoLibraryChangeObserver` on the "all assets" fetch result for instant updates while the app is open.

Keys: `localIdentifier` is the primary key. Also store the `cloudIdentifier` (`cloudIdentifierMappings(forLocalIdentifiers:)`) so the index can be re-attached after a device restore where local ids may differ.

Rejected: polling `PHAsset.fetchAssets` sorted by modification date. Misses deletions and edits cleanly, and costs a full fetch each time.

### D2. Index from local thumbnails; never trigger iCloud downloads in the default pass

Most users have "Optimize iPhone Storage" on, so originals are often not on the device. Small renditions almost always are. The extractors run on a ~512 px longest-side image, which is enough for CLIP (256 px input), classification, faces and aesthetics. OCR gets a 1024 px rendition when the asset is a screenshot or when the cheap text-presence check fires.

Request options: `isNetworkAccessAllowed = false`, `deliveryMode = .highQualityFormat`, `resizeMode = .fast`, `isSynchronous = true` on a bounded worker queue. If the result is degraded or `PHImageResultIsInCloudKey` is set, mark the job `needs_network` and leave it for the opt-in "fetch from iCloud on Wi-Fi + charging" pass. That pass is a user setting, default off.

### D3. One semantic embedding: MobileCLIP (Core ML), used for both text→image search and image→image similarity

Apple's Vision `GenerateImageFeaturePrintRequest` gives a good similarity vector but it is not aligned with text, so it cannot answer "photos of a red bike". Photos.app's own semantic embeddings are not exposed by any public API.

Choice: Apple's MobileCLIP (S2 by default; S0 on memory-constrained devices), Core ML, 512-d output, ANE-resident. Image encoder runs at index time; text encoder runs at query time. Cosine similarity.

Delivery: bundle the image encoder in the app (it's needed for indexing from first launch). Download the text encoder and any larger variant with Background Assets on first launch. If the binary size budget allows, bundle both and skip the download path entirely; decide after measuring fp16 sizes.

Vision feature print is not stored in v1. Near-duplicate detection uses CLIP cosine > 0.97 plus same capture minute; revisit if precision is poor.

### D4. Signal set per photo (v1)

| Signal | API | Cost class | Stored as |
|---|---|---|---|
| Semantic embedding | MobileCLIP image encoder (Core ML) | cheap | 512 × Float16 blob |
| Scene labels | Vision `ClassifyImageRequest` (~1,300 classes), keep confidence ≥ 0.3, top 15 | cheap | `labels` rows + FTS |
| OCR text | Vision `RecognizeTextRequest` `.accurate`, gated (see D5) | expensive | FTS |
| Structured documents | Vision `RecognizeDocumentsRequest` (iOS 26) for receipts/tables, gated to screenshots + documents | expensive | JSON payload + FTS |
| Faces | Vision `DetectFaceRectanglesRequest` — count + boxes only, no identity | cheap | `faces` rows |
| Aesthetics / utility flag | Vision `CalculateImageAestheticsScoresRequest` (iOS 18) | cheap | column on `assets` |
| Metadata | PhotoKit: date, GPS, media subtypes (screenshot, live, HDR, burst), favorite, hidden, duration, pixel size | free | `assets` columns |
| Place names | Offline gazetteer lookup from GPS (see D8) | free | `places` row + FTS |
| Caption + entities | Foundation Models from the structured signals above (Enhanced tier only) | expensive, rate-limited in background | FTS |

Stages are independent and idempotent: a photo with only embedding + labels is already searchable.

### D5. Pipeline order and gating (cost control)

Per asset, in order: metadata → thumbnail → CLIP → labels → faces → aesthetics → [OCR] → [documents] → [LLM caption].

OCR gate: run OCR if `mediaSubtypes.contains(.photoScreenshot)`, or the label set includes text-bearing classes (document, receipt, sign, menu, whiteboard, screen…), or a fast `RecognizeTextRequest(.fast)` on the 512 px rendition finds ≥ 3 words. Roughly 10–25% of a typical library needs full OCR.

LLM caption gate: Enhanced tier, app in foreground or in a continued-processing task, thermal state nominal/fair, and the asset is not a `isUtility` image. Never blocks search readiness.

Ballpark per photo on an A17 class chip (measure, don't trust): thumbnail 5–10 ms, CLIP 5 ms, labels 15 ms, faces 8 ms, aesthetics 5 ms, accurate OCR 150–400 ms. Blended ≈ 60–100 ms per photo → 30k photos in roughly 30–50 minutes of compute.

### D6. Storage: a single SQLite database (GRDB), vectors as blobs, brute-force search via Accelerate

Schema (sketch):

```sql
assets(id TEXT PRIMARY KEY, cloud_id TEXT, media_type INT, subtypes INT,
       created_at REAL, modified_at REAL, width INT, height INT,
       lat REAL, lon REAL, is_favorite INT, is_hidden INT, duration REAL,
       aesthetic REAL, is_utility INT, face_count INT,
       index_state INT, indexed_at REAL);
asset_features(asset_id, extractor TEXT, version INT, payload BLOB,
               PRIMARY KEY(asset_id, extractor));          -- raw per-extractor output
embeddings(asset_id TEXT PRIMARY KEY, model TEXT, dims INT, vec BLOB); -- Float16
labels(asset_id, label TEXT, confidence REAL);              -- index(label)
faces(asset_id, idx INT, x REAL, y REAL, w REAL, h REAL, quality REAL);
places(asset_id TEXT PRIMARY KEY, country TEXT, admin TEXT, locality TEXT);
asset_text USING fts5(asset_id UNINDEXED, ocr, labels, caption, place, tokenize='unicode61 remove_diacritics 2');
index_jobs(asset_id, stage TEXT, priority INT, attempts INT, not_before REAL,
           needs_network INT, last_error TEXT, PRIMARY KEY(asset_id, stage));
sync_state(key TEXT PRIMARY KEY, value BLOB);               -- change token, schema/extractor versions
```

Vector search: on first query, load `embeddings` into one contiguous `[Float16]` (plus a parallel id array) held by `SearchEngine`; score with `vDSP`/BNNS dot products. 50k photos × 512 × 2 bytes = 50 MB, scored in well under 50 ms. The cache is invalidated by insert/delete counters in `sync_state`. Metadata filters run in SQL first and the vector pass scores only the candidate id set when the filter is selective, otherwise scores everything and joins.

Upgrade path (not v1): if libraries above ~150k photos become common, move `embeddings` to sqlite-vec (`vec0`, int8) or USearch HNSW. The `IndexStore` API hides this.

Rejected for v1: Core Data/SwiftData (poor fit for FTS and blobs at this volume), ObjectBox/Couchbase (heavy deps for a solo-maintained app), sqlite-vec as a hard dependency (pre-1.0, needs static extension registration against the system SQLite).

File protection: `.completeUntilFirstUserAuthentication` so background tasks can run after the first unlock. The database is marked `isExcludedFromBackup = true`; it's fully derivable and re-attaches via `cloud_id` after a restore. Photos permission: request `.readWrite` access level and fully support `.limited` (show `presentLimitedLibraryPicker`; a limited selection just means a smaller library).

### D7. Scheduling: three execution modes plus a policy layer

1. **Initial index** — user taps "Index my library". Start in the foreground with a progress UI; on backgrounding, hand off to a `BGContinuedProcessingTask` (iOS 26) so the system shows progress and lets the work continue, with `Progress` updated every batch. On iOS 18–25, the work continues only while the app is open or via mode 2; tell the user to leave the app open on charge.
2. **Nightly maintenance** — `BGProcessingTask` with `requiresExternalPower = true`, `requiresNetworkConnectivity = false`. Drains the job queue (new photos, model-version re-index, deferred OCR/LLM stages). Reschedule itself on completion. Budget: stop cleanly when `expirationHandler` fires; every batch is a transaction, so nothing is lost.
3. **Foreground incremental** — change observer + short `BGAppRefreshTask` to pick up the day's photos so "search the photo I just took" works within seconds.

Policy (applies to all modes): batch size 16–32 assets inside `autoreleasepool`; max 2 concurrent thumbnail requests; pause when `ProcessInfo.thermalState` is `.serious` or worse; halve throughput in Low Power Mode; skip LLM stage unless charging.

Job priority: newest photos first, then favorites, then the rest in reverse-chronological order. The user sees recent memories become searchable immediately.

### D8. Place names without a network call

`CLGeocoder` and `MKLocalSearch` hit Apple servers, which breaks "nothing leaves the device". Bundle an offline gazetteer (GeoNames cities15000 ≈ 25k rows, a few MB) with a k-d tree or coarse grid lookup, giving country / admin area / city. That's enough for "photos in Tokyo" and "trip to Portugal". If the user later opts in, `CLGeocoder` can refine to neighborhood level; opt-in, off by default.

### D9. Versioned extractors, lazy re-index

Every `FeatureExtractor` has `(id, version)`. `asset_features.version` records what produced each row. Bumping a version (new MobileCLIP variant, better OCR) enqueues only that stage for all assets, at low priority, during nightly maintenance. Search keeps working on old vectors until the new pass completes; embeddings from different model versions are never mixed in one scoring pass (search uses the version with the most coverage until the migration is done).

### D10. Search: hybrid retrieval with rank fusion

Query → `ParsedQuery { text, dateRange, place, subtypes, minFaces, isFavorite }`.

- Enhanced tier: Foundation Models with a `@Generable ParsedQuery` and a short system prompt. Sub-100 ms and fully local.
- Baseline tier: NaturalLanguage `NLTagger` for dates/places plus a rule table (screenshot, selfie, last summer, etc.).

Retrieval:
1. SQL filter from structured fields → candidate set.
2. FTS5 BM25 over OCR + labels + caption + place (exact words, receipts, names on screenshots).
3. MobileCLIP text encoder → cosine over candidates.
4. Reciprocal Rank Fusion of 2 and 3, small boosts for favorites and aesthetics, penalty for `is_utility` unless the query is about screenshots/documents.

Results return asset ids; the UI loads thumbnails with `PHCachingImageManager`.

### D11. People identity is phase 2, opt-in

Vision gives face boxes but no identity embedding, and PhotoKit doesn't expose the Photos People album. Identity clustering needs a bundled face-embedding model and carries biometric-law obligations in several jurisdictions. v1 indexes face count and box sizes (enough for "selfies", "group photos"). Phase 2 adds opt-in local clustering with user-named clusters, stored only on device.

### D12. Videos and Live Photos

v1 indexes Live Photos via their still. Videos get metadata only. Phase 2: sample 3–5 frames with `AVAssetImageGenerator`, embed each, store multiple vectors per asset (max-pool at scoring time).

## 5. Storage and time budget

Per 10k photos (estimates):

| Item | Size |
|---|---|
| Embeddings (512 × Float16) | ~10 MB |
| Labels + faces + places rows | ~5 MB |
| FTS (OCR heavy libraries) | 5–30 MB |
| Raw feature payloads | ~10 MB (optional, can be dropped after search fields are derived) |

Model assets: MobileCLIP-S2 image encoder ~70 MB fp16, text encoder ~125 MB fp16; S0 roughly half. Measure before deciding bundle vs download.

## 6. Privacy boundaries (enforced by structure, not policy)

- `PhotoSource`, `Extractors`, `IndexStore`, `IndexScheduler`, `SearchEngine` are compiled without any URL-loading code and have no network entitlement. A lint rule fails the build if `URLSession`/`Network` is imported in those targets.
- The only egress path is the future `ContextBroker`, which produces **text** (captions, labels, dates, places; never pixels, never raw OCR unless the user reviews it) and requires explicit per-request consent.
- No analytics SDKs. Crash reports contain no asset ids.
- Hidden album assets are indexed only if the user enables it (default off) and are never surfaced in ContextBroker output.

## 7. Failure modes to design for

- Change token expired → reconciliation pass (D1).
- Asset deleted mid-job → job fails with `PHPhotosError.invalidResource`; drop the job and cascade-delete rows.
- App killed mid-batch → every batch is one SQLite transaction; token only advances after commit.
- Model file missing/corrupt (download path) → Baseline-minus mode: labels + OCR + metadata search still work; show a banner.
- Thermal throttling → scheduler pauses; resumes via `ProcessInfo.thermalStateDidChangeNotification`.
- Memory pressure on 4 GB devices → smaller batch, drop to MobileCLIP-S0, no OCR in the same batch as CLIP.

## 8. Build order

1. `PhotoSource` with change tokens + reconciliation, `IndexStore` with schema + migrations. Metadata-only index and a date/place/subtype search. Ship internally.
2. MobileCLIP embedding + labels + vector search + FTS. This is the moment search becomes "magic".
3. Scheduler: continued-processing task, nightly task, policy layer, progress UI.
4. OCR + documents gating; faces + aesthetics.
5. Enhanced tier: Foundation Models captions and query parsing.
6. Phase 2: people clustering, video frames, ContextBroker.

## 9. Reserved boundary: ContextBroker (out of scope now)

The remote LLM never sees the index. It sends a question; `ContextBroker` runs `SearchEngine`, builds a compact text bundle (top-N assets: date, place, labels, caption, OCR snippet, aesthetic flag), shows it to the user for approval, and only then hands it to the network layer. That contract is the only thing the rest of the system needs to honor today: every search result must be renderable as plain text.

## 10. Open decisions (owner's call)

1. Minimum iOS: 18 (recommended; gives the Swift Vision API and aesthetics scoring) vs 26 (simpler, but cuts a large share of devices this year).
2. Bundle both MobileCLIP encoders (bigger app, zero first-run download) vs Background Assets download. Recommendation: bundle the image encoder, download the text encoder.
3. Include videos in v1 (metadata only, recommended) or defer entirely.
4. Store raw extractor payloads (`asset_features`) for future re-derivation, or keep only search-ready fields. Recommendation: store them; it's ~1 MB per 1k photos.
