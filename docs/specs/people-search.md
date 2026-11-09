# Spec: People search (name a face, find that person)
Status: final        Owner: ponikar        Created: 2026-11-08
Mark anything unknown as `[?]`. The spec is not final while a `[?]` remains.

## 1. Problem
Users search "darshan having coffee at cafe" and get photos of any coffee, because nothing in the index knows who is in a photo.
They need to name a person once and then find that person's photos by name, alone or combined with what is happening.
Today the index stores CLIP embeddings, Vision labels, OCR text and places; faces are not detected or stored, and Photos' People names have no public API.

## 2. Users and flows
- The indexer detects every face in a photo, crops it, and stores one face fingerprint per face, in the background.
- The app lists unnamed face groups so the user can see "who is this?".
- The user names one face ("Darshan") and the name spreads to every face close enough to it.
- The user fixes a wrong face by naming it differently or removing its name.
- The indexer names faces in newly added photos automatically from the faces already named.
- The user searches "darshan having coffee at cafe" and gets only photos with Darshan, ranked by "having coffee at cafe".

## 3. Requirements
- R-01 WHEN a photo is indexed, THE SYSTEM SHALL store one face record per detected face with its asset, normalized bounding box and fingerprint.
- R-02 WHEN a photo has no faces, THE SYSTEM SHALL store no face records and mark the face stage complete for it.
- R-03 WHEN the app asks for face groups, THE SYSTEM SHALL return the stored groups, each with its face references, photo count and the person name shared by its faces if any.
- R-04 WHEN the user names one face, THE SYSTEM SHALL store that name on that face as a user name and recompute every automatic name.
- R-05 THE SYSTEM SHALL give a face without a user name the automatic name P only when the nearest user-named face is named P, is within the cutoff, and every user-named face of another person is at least 10% of the cutoff farther; otherwise it has no name.
- R-06 WHEN the user renames or unnames a face, THE SYSTEM SHALL change only that face's user name, recompute every automatic name, and never change another face's user name.
- R-07 WHEN a batch of new photos is saved, THE SYSTEM SHALL assign each new face a group and an automatic name by the R-05 rule in the same save.
- R-15 WHEN the naming order differs but the user names are the same, THE SYSTEM SHALL produce the same automatic names.
- R-16 WHEN a photo is indexed again with the same face model, THE SYSTEM SHALL keep the same face ids and their user names.
- R-08 WHEN a photo contains several people, THE SYSTEM SHALL return it for a search on any one of their names.
- R-09 WHEN a query contains a known person name, THE SYSTEM SHALL return only photos containing that person, ranked by the rest of the query with the existing probability scoring.
- R-10 WHEN a query is only a known person name, THE SYSTEM SHALL return that person's photos newest first with probability 1.
- R-11 WHEN a query contains two known person names, THE SYSTEM SHALL return only photos containing both.
- R-12 WHEN a photo is deleted from the library, THE SYSTEM SHALL delete its face records.
- R-13 WHEN the face stage version changes, THE SYSTEM SHALL re-run face extraction and move each user name to the new face in the same photo whose box overlaps the old box by IoU >= 0.5, dropping names with no such face.
- R-14 The React Native binding SHALL expose `faceGroups()`, `nameFace(faceId, name)`, `unnameFace(faceId)`, and report `'person'` in `matchedBy` for person matches.
- R-17 WHEN a person is named or unnamed, THE SYSTEM SHALL use the new name list on the next search without reconfiguring.

## 4. Edge cases
| Case | Expected behaviour | Covers |
|---|---|---|
| photo with no faces | no face rows, stage complete | R-02 |
| group photo, 5 faces | 5 face rows, photo found by each name | R-01, R-08 |
| tiny face | skipped when its box is under 64 px on the short side in the 1024 px image the face stage loads | R-01 |
| two people look alike | face left unnamed, shown in "who is this?" | R-05 |
| user names a face wrong, then fixes it | only that face's user name changes; automatic names recomputed by R-05 | R-06 |
| name A then B vs B then A | identical automatic names | R-15 |
| user-named face vs auto-named face disagree | user name always wins | R-06 |
| new photo after naming | named automatically if one person matches | R-07 |
| query name not known ("vietnam", "bob") | handled as today (place or content) | R-09 |
| person name equals a place name ("paris") | person wins | R-09 |
| two names in query | photos with both | R-11 |
| photo deleted | its faces removed, names stay on other faces | R-12 |
| model upgraded | user names moved by box overlap in the same photo; automatic names recomputed | R-13 |
| re-index same photo | same face ids, no duplicate rows, user names kept | R-16 |
| name a new person, then search | new name found without restart | R-17 |
| 10k faces | listing groups reads stored group ids, under 500 ms on iPhone | R-03 |
| photo with faces of two named people | each face named separately, photo matches both names | R-08, R-11 |

## 5. Out of scope
- Reading names from the Photos app People album (no public API).
- On-device LLM query parsing (FoundationModels); names are found by matching the vocabulary, like places.
- Time phrases in queries ("last summer").
- Pets as people.
- Sending faces or fingerprints off the device.
- UI in the eval app beyond what tests need.

## 6. Constraints
- Reuse `FeatureExtractor` + `IndexCoordinator` for the face stage: new `IndexStage.faces`, new `FeatureValue.faces([DetectedFace])` (one value per photo holding all its faces), `preferredPixelSize` 1024.
- Face id = asset id + box rounded to 3 decimals; stable while the image and model are unchanged.
- Storage (migration 3): `face` table (face id, asset id with ON DELETE CASCADE, box, fingerprint, group id, automatic name) and `face_name` table (face id, asset id with ON DELETE CASCADE, user name). Re-extraction replaces `face` rows only; `face_name` rows survive and are re-attached per R-13.
- Groups are stored, not computed per request: a new face joins the group of its nearest face within the cutoff, else starts a new group. Users never name groups.
- Automatic naming and grouping run inside `SQLiteIndexStore.commit` for the batch's faces, and over all faces after any user-name change. Extractors stay pure.
- Cutoff reaches the store as a new `SQLiteIndexStore.init(path:faceCutoff:)` parameter with a default; `IndexStore`/`IndexBatch` unchanged.
- `PersonIndex` (PicknickCore) exposes: `personNames() -> [String]`, `assets(withAll names: [String], filter: SearchFilter, limit: Int) -> [AssetID]` (newest first), `faceGroups() -> [FaceGroup]`, `nameFace(_ id: FaceID, as name: String)`, `unnameFace(_ id: FaceID)`. `SearchEngine.init` gains an optional `people: (any PersonIndex)?` parameter, default nil.
- A query with a person and a known place restricts to photos with the person AND in the place; remaining words rank them.
- The face extractor returns `.faces([])` for zero faces (never nil), so a re-run always replaces old face rows.
- On every face replacement for a photo, user names re-attach by exact face id first, else by IoU >= 0.5, else are dropped; no version detection needed.
- Two detections with the same rounded box in one photo keep only the first.
- Stored boxes are normalized 0-1 with origin top-left (flip Vision's bottom-left like `VisionTextExtractor`).
- RN `PicknickService` keeps the store and calls `PersonIndex` methods on it for R-14.
- Distance = Euclidean distance between stored fingerprint vectors, the same value as `FeaturePrintObservation.distance(to:)`; "within the cutoff" means distance <= cutoff.
- Face detection with Vision `DetectFaceRectanglesRequest`.
- Face fingerprint: Vision `GenerateImageFeaturePrintRequest` on a square crop 1.8x the face box. No bundled face model.
- Similarity cutoff: a configuration value; default chosen by the face eval (section 8).
- New SQLite tables through a forward-only migration (version 3); existing tables unchanged.
- Person-name matching mirrors `splitKnownPlaces` in `SearchEngine`, but names are read from the index on every search (new `PersonIndex` protocol in PicknickCore, implemented by `SQLiteIndexStore`), not frozen at init.
- Public API additions only: `SearchSignal.person`, RN `MatchSignal` gains `'person'`, new RN types `FaceGroup { id, name?, photoCount, faces: FaceRef[] }` and `FaceRef { faceId, photoId, uri, box: { x, y, width, height } }` (box normalized 0-1, origin top-left).
- Swift 6, iOS 18 / macOS 15, no third-party Swift dependencies.

## 7. Boundaries for the agents
- Always: follow existing module patterns; run `swift test`; no comments unless the reason is non-obvious.
- Ask first: new dependency, changes to existing tables, changes to `SearchQuery`/`SearchResult` public shape beyond adding fields.
- Never: push, or send data off device.

## 8. Done means
- R-01, R-02 -> unit -> extractor on fixture images with 0, 1, 3 faces gives 0, 1, 3 records with boxes.
- R-03, R-04, R-05, R-15 -> unit -> store with synthetic fingerprints: grouping, naming, ambiguous face stays unnamed, both naming orders give the same names.
- R-06 -> unit -> rename one face, user-named neighbours unchanged.
- R-07 -> integration -> index, name, add photo, face named automatically.
- R-08, R-09, R-10, R-11 -> unit -> SearchEngine with stub faces: filters and ordering.
- R-12 -> integration -> delete asset, face rows gone.
- R-13 -> unit -> bump version with shifted boxes, user names moved by IoU, unmatched dropped.
- R-16 -> unit -> commit the same faces twice, ids and user names unchanged.
- R-17 -> unit -> name a face, search by that name with the same engine instance.
- R-14 -> typecheck + example self-test calls the new methods.
- Cutoff -> eval -> labelled face set (public photos of known people, several per person, incl. group photos): for each cutoff, report share of auto-named faces that are correct and share of faces named; default = the cutoff with the most faces named while at least 90% are correct. Result recorded in the decisions log.

## 9. Pointers
Sources/PicknickCore/Protocols/FeatureExtractor.swift
Sources/PicknickCore/Model/IndexStage.swift
Sources/PicknickCore/Model/Feature.swift
Sources/PicknickCore/Protocols/PlaceVocabulary.swift
Sources/PicknickIndexer/IndexCoordinator.swift
Sources/PicknickStore/Schema/Migration.swift
Sources/PicknickStore/SQLiteIndexStore+Search.swift
Sources/PicknickSearch/SearchEngine.swift
Sources/PicknickVision/VisionLabelExtractor.swift
lib/react-native/src/specs/Picknick.nitro.ts
lib/react-native/ios/PicknickService.swift

## 10. Decisions log
2026-11-08 Name single faces, not whole groups; groups are stored and never named. User decision in chat; storage choice after verification.
2026-11-08 Cluster faces, not photos, so group photos belong to every person in them. User decision in chat.
2026-11-08 New photos are named from existing named faces at index time. User decision in chat.
2026-11-08 Fingerprint uses Apple's built-in feature print, no extra model. User decision.
2026-11-08 Cutoff and accuracy bar set by eval, target 90% correct. User: "use evals".
2026-11-08 Minimum face 64 px and 500 ms group listing chosen by Claude; user had no preference.
2026-11-08 Person wins over place on name clash. User agreed.
2026-11-08 Verification round 2 (7 gaps) filled by Claude: cutoff via store init; PersonIndex methods; person+place = AND; `.faces([])` for zero; reattach by id then IoU on every replace; duplicate boxes deduped; top-left boxes; RN keeps store. Edited/cropped photos keep stale boxes until re-index (accepted; existing behaviour for all stages).
2026-11-08 Verification round 1 (7 gaps) filled by Claude at user request: names in their own table keyed by stable face id; IoU carry-over on model change; naming inside store commit; order-independent R-05 rule; names read per search; RN shapes and `person` signal added.
2026-11-08 Face eval (200 LFW photos, 20 people, 166 scored faces): no useful cutoff reaches 90% correct. Best: 0.68 names 0.6% at 100%; 0.58 names 17% at 82%; 0.49 names 30% at 72%. Nearest-person accuracy 51% (chance 5%). Default set to 0.68 per section 8 rule. Apple's feature print is too weak for identity; a face model is needed to meet the bar.
2026-11-09 Built-in only, improved: square crop 1.8x the face box (nearest-person accuracy 47% -> 79%); R-05 changed from "all named faces within cutoff agree" to "clear nearest person" (more faces named at the same accuracy); rotation by face roll gave no clear gain on LFW (already aligned). Eval: cutoff 0.72 names 58% of faces at 97% correct. Face stage version 2 re-indexes faces. Cutoff was tuned and measured on the same 200 photos; accuracy on a personal library is not measured.
