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
- GeoNames `cities15000.txt`, `countryInfo.txt` and `admin1CodesASCII.txt`: https://download.geonames.org/export/dump/

## Known limits

- Tested on macOS, the iOS Simulator and one iPhone.
- Vision labels fail in the iOS Simulator. Use a device.
- The match probability was calibrated on 298 COCO photos. Your library may score differently.
- Nonsense words ("xqzvbt") can still match photos with probability up to about 0.9. A minimum of 0.9 removes them but also drops many real matches. Well-known place names with no photos there ("vietnam") return nothing.

## React Native

`lib/react-native` wraps the library as a [Nitro](https://nitro.margelo.com) module (iOS only; tested with React Native 0.88 and Nitro 0.37).

```sh
npm install react-native-nitro-modules ./path/to/picknick/lib/react-native
cd ios && pod install
```

Add the model and GeoNames files to your iOS app target (Xcode compiles each `.mlpackage` into `.mlmodelc`), and add `NSPhotoLibraryUsageDescription` to `Info.plist`. To show results with `<Image>`, also install `@react-native-camera-roll/camera-roll`, which loads `ph://` URIs.

```ts
import { Picknick } from 'react-native-picknick'

await Picknick.configure({
  imageModel: 'mobileclip_s2_image.mlmodelc',
  textModel: 'mobileclip_s2_text.mlmodelc',
  merges: 'bpe_merges.txt',
  cities: 'cities15000.txt',
  countryInfo: 'countryInfo.txt',
  admin1Codes: 'admin1CodesASCII.txt',
})

await Picknick.requestPhotoAccess()
await Picknick.indexLibrary((status) => console.log(`${status.searchable}/${status.total}`))

const hits = await Picknick.search('dog on a beach', { topN: 20, minimumProbability: 0.5 })
// hits: { id, uri: 'ph://…', probability, matchedBy }[]
```

File names are looked up in the app bundle; absolute paths work too. `getStatus()` reports progress at any time.

The example app in `lib/react-native/example` has a search screen and a self-test (`scripts/selftest.sh`) that checks ordering, Top N, the minimum probability and a no-match query.

## Tests

```
swift test
```
