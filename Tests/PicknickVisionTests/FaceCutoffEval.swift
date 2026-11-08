import CoreGraphics
import Foundation
import ImageIO
import PicknickCore
import PicknickVision
import Testing

/// Picks the face cutoff (spec section 8). PICKNICK_FACE_EVAL points to a folder of
/// person-named subfolders of photos. Only faces from photos with exactly one face
/// are labelled, because a group photo does not say which face is the folder's person.
private let evalFolder = ProcessInfo.processInfo.environment["PICKNICK_FACE_EVAL"]

private struct LabelledFace {
    let person: String
    let fingerprint: [Float]
}

private func distance(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for (x, y) in zip(a, b) { sum += (x - y) * (x - y) }
    return sum.squareRoot()
}

private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

@Suite("Face cutoff eval")
struct FaceCutoffEval {
    @Test("Sweep cutoffs and report share named and share correct", .enabled(if: evalFolder != nil))
    func sweep() async throws {
        let root = URL(fileURLWithPath: try #require(evalFolder))
        let manager = FileManager.default
        let extractor = VisionFaceExtractor()
        var labelled: [LabelledFace] = []
        var groupFaces = 0
        var photos = 0

        let people = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in people {
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let image = loadImage(file) else { continue }
                photos += 1
                let value = try await extractor.extract(ExtractionContext(metadata: AssetMetadata(id: AssetID(file.path)), image: image))
                guard case .faces(let faces) = value else { continue }
                if faces.count == 1 {
                    labelled.append(LabelledFace(person: folder.lastPathComponent, fingerprint: faces[0].fingerprint))
                } else {
                    groupFaces += faces.count
                }
            }
        }

        var seeds: [String: LabelledFace] = [:]
        var rest: [LabelledFace] = []
        for face in labelled {
            if seeds[face.person] == nil { seeds[face.person] = face } else { rest.append(face) }
        }
        print("face eval: \(photos) photos, \(seeds.count) people, \(labelled.count) labelled faces, \(groupFaces) faces in multi-face photos skipped")
        try #require(!rest.isEmpty, "need at least two single-face photos for some person")

        let distances = rest.map { face in seeds.values.map { (distance(face.fingerprint, $0.fingerprint), $0.person) } }
        let all = distances.flatMap { $0.map(\.0) }.sorted()
        let cutoffs = Array(Set((1...40).map { all[min(all.count - 1, all.count * $0 / 40)] })).sorted()

        var best: (cutoff: Float, named: Double, correct: Double)?
        print("cutoff\tnamed\tcorrect")
        for cutoff in cutoffs {
            var named = 0
            var correct = 0
            for (face, candidates) in zip(rest, distances) {
                let within = Set(candidates.filter { $0.0 <= cutoff }.map(\.1))
                guard within.count == 1, let person = within.first else { continue }
                named += 1
                if person == face.person { correct += 1 }
            }
            let namedShare = Double(named) / Double(rest.count)
            let correctShare = named == 0 ? 0 : Double(correct) / Double(named)
            print(String(format: "%.4f\t%.3f\t%.3f", cutoff, namedShare, correctShare))
            if named > 0, correctShare >= 0.9, namedShare > (best?.named ?? -1) {
                best = (cutoff, namedShare, correctShare)
            }
        }
        if let best {
            print(String(format: "face eval best cutoff: %.4f (named %.3f, correct %.3f)", best.cutoff, best.named, best.correct))
        } else {
            print("face eval best cutoff: none reaches 90% correct")
        }
    }
}
