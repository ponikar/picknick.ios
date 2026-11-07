# Picknick

On-device photo search for iOS. Nothing leaves the device.

## What it does

- Searches photos by meaning ("dog on a beach") using MobileCLIP image and text embeddings.
- Adds Vision labels and recognized text in photos (text recognition runs on screenshots by default).
- Names places offline from GeoNames data, so "Paris" finds photos taken there.
- Gives every result a 0–1 probability that it matches the query. You set how many results to return and the minimum probability.
- Optionally hands a remote AI a text-only summary of matching photos, only after the user approves it.

## Modules

| Module | Role |
|---|---|
| `PicknickCore` | Shared types and protocols. |
| `PicknickStore` | `SQLiteIndexStore`: the index in one SQLite file. |
| `PicknickPhotos` | `PhotoKitLibrary` and `PhotoKitImageLoader` over PhotoKit. |
| `PicknickIndexer` | `IndexCoordinator`: scans the library and runs extractors. |
| `PicknickCLIP` | `CLIPImageExtractor` and `CLIPTextEmbedder` (MobileCLIP via Core ML). |
| `PicknickVision` | `VisionLabelExtractor` and `VisionTextExtractor`. |
| `PicknickPlaces` | `Gazetteer`, `PlaceResolver`, `PlaceNameIndex` (offline GeoNames). |
| `PicknickSearch` | `SearchEngine`, `SearchQuery`, `SearchResult`. |
| `PicknickBroker` | `ContextBroker`: consent-gated text context for a remote AI. |
| `PicknickTestSupport` | In-memory library and stubs for tests. |

The package has no third-party dependencies.

## Install

Requires iOS 18 or macOS 15, Swift tools 6.0.

```swift
dependencies: [
    .package(url: "https://github.com/ponikar/picknick.ios", branch: "main")
]
```

Then add the products you need, for example `Picknick`, `PicknickCLIP`, `PicknickVision`, `PicknickPlaces` and `PicknickSearch`.

## Quick start

```swift
let gazetteer = try Gazetteer(
    citiesURL: citiesURL,
    countryInfoURL: countryInfoURL,
    admin1CodesURL: admin1CodesURL
)
let store = SQLiteIndexStore(path: databaseURL.path)

let coordinator = IndexCoordinator(
    library: PhotoKitLibrary(),
    store: store,
    imageLoader: PhotoKitImageLoader(),
    extractors: [
        CLIPImageExtractor(modelURL: imageModelURL),
        VisionLabelExtractor(),
        VisionTextExtractor(),
    ],
    placeNaming: PlaceResolver(gazetteer: gazetteer)
)
try await coordinator.run()

let engine = SearchEngine(
    index: store,
    embedder: CLIPTextEmbedder(modelURL: textModelURL, mergesURL: mergesURL),
    placeVocabulary: PlaceNameIndex(gazetteer: gazetteer)
)
let results = try await engine.search(
    SearchQuery("dog on a beach", limit: 20, minimumProbability: 0.5)
)
// results: [SearchResult], each with `id` (AssetID) and `score` (0–1)
```

`run()` is safe to call again; it only processes new or changed photos. Ask for photo library access (`PhotoKitLibrary().requestAuthorization()`) before running it.

## Files you supply

The package bundles none of these. Ship them in your app and pass their URLs.

- MobileCLIP S2 Core ML image and text encoders: https://huggingface.co/apple/coreml-mobileclip
- CLIP BPE merges file `bpe_simple_vocab_16e6.txt` from https://github.com/openai/CLIP, uncompressed.
- GeoNames `cities15000.txt`, `countryInfo.txt` and `admin1CodesASCII.txt`.

## Known limits

- Tested on macOS, the iOS Simulator and one iPhone.
- Vision labels fail in the iOS Simulator. Use a device.
- The match probability was calibrated on 298 COCO photos. Your library may score differently.
- Nonsense words can still return low-probability matches. Raise `minimumProbability` to drop them.

## Tests

```
swift test
```
