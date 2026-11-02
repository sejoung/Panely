import Foundation

/// Same pinned OCR artifacts as PanelyWindows. Files are verified before installation.
nonisolated enum ComicOCRModels {
    static let revision = "manga-c68e56437a2e+ppocr-3b76726c3606-v1"
    static var cacheRevision: String {
        let root = TranslationModelFiles.defaultRoot()
        let forcedVision = ProcessInfo.processInfo.environment["PANELY_OCR_ENGINE"] == "vision"
        return !forcedVision && isInstalled(at: root, manga: true) && isInstalled(at: root, manga: false)
            ? revision : "vision-v2"
    }
    static let files: [TranslationModel] = [
        TranslationModel(
            id: "manga-ocr-int8", displayName: "manga-ocr",
            revision: "c68e56437a2e0b13a7b1f4efa0ffce76efd0478d", fileName: "encoder_model_int8.onnx",
            bytes: 87074595, sha256: "0eaf2b867292a44700ce38ef028b90639a2e36fc4c18c2bcdd1de7409488adb3",
            url: URL(string: "https://huggingface.co/ogkalu/manga-ocr-onnx/resolve/c68e56437a2e0b13a7b1f4efa0ffce76efd0478d/encoder_model_int8.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "manga-ocr-int8", displayName: "manga-ocr",
            revision: "c68e56437a2e0b13a7b1f4efa0ffce76efd0478d", fileName: "decoder_model_int8.onnx",
            bytes: 29675736, sha256: "3ff0d4c34c4a66613d98ff93e0b17f22a7b09dfbeec195c3e4d6f595af3a6b6c",
            url: URL(string: "https://huggingface.co/ogkalu/manga-ocr-onnx/resolve/c68e56437a2e0b13a7b1f4efa0ffce76efd0478d/decoder_model_int8.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "manga-ocr-int8", displayName: "manga-ocr",
            revision: "c68e56437a2e0b13a7b1f4efa0ffce76efd0478d", fileName: "vocab.txt",
            bytes: 30216, sha256: "5cb5c5586d98a2f331d9f8828e4586479b0611bfba5d8c3b6dadffc84d6a36a3",
            url: URL(string: "https://huggingface.co/ogkalu/manga-ocr-onnx/resolve/c68e56437a2e0b13a7b1f4efa0ffce76efd0478d/vocab.txt")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "ch_PP-OCRv5_mobile_det.onnx",
            bytes: 4819576, sha256: "4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/ch_PP-OCRv5_mobile_det.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "ch_PP-OCRv5_rec_mobile_infer.onnx",
            bytes: 16631306, sha256: "5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/ch_PP-OCRv5_rec_mobile_infer.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "en_PP-OCRv5_rec_mobile_infer.onnx",
            bytes: 7872351, sha256: "c3461add59bb4323ecba96a492ab75e06dda42467c9e3d0c18db5d1d21924be8",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/en_PP-OCRv5_rec_mobile_infer.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "korean_PP-OCRv5_rec_mobile_infer.onnx",
            bytes: 13488748, sha256: "cd6e2ea50f6943ca7271eb8c56a877a5a90720b7047fe9c41a2e541a25773c9b",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/korean_PP-OCRv5_rec_mobile_infer.onnx")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "ppocrv5_dict.txt",
            bytes: 74012, sha256: "d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/ppocrv5_dict.txt")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "ppocrv5_en_dict.txt",
            bytes: 1416, sha256: "e025a66d31f327ba0c232e03f407ae8d105e1e709e7ccb3f408aa778c24e70d6",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/ppocrv5_en_dict.txt")!, license: "Apache-2.0"
        ),
        TranslationModel(
            id: "ppocr-v5-mobile", displayName: "PP-OCRv5 mobile",
            revision: "3b76726c3606c4af92f5133b359ed14e0d30a455", fileName: "ppocrv5_korean_dict.txt",
            bytes: 47451, sha256: "a88071c68c01707489baa79ebe0405b7beb5cca229f4fc94cc3ef992328802d7",
            url: URL(string: "https://huggingface.co/ogkalu/ppocr-v5-onnx/resolve/3b76726c3606c4af92f5133b359ed14e0d30a455/ppocrv5_korean_dict.txt")!, license: "Apache-2.0"
        ),
    ]

    static func files(at root: URL, manga: Bool) -> [TranslationModelFiles] {
        files.filter { ($0.id == "manga-ocr-int8") == manga }.map { TranslationModelFiles(root: root, model: $0) }
    }

    static func isInstalled(at root: URL, manga: Bool) -> Bool {
        files(at: root, manga: manga).allSatisfy(\.isInstalled)
    }

    static func url(_ name: String, at root: URL) throws -> URL {
        guard let model = files.first(where: { $0.fileName == name }) else { throw TranslationModelError.notInstalled }
        let file = TranslationModelFiles(root: root, model: model)
        guard file.isInstalled else { throw TranslationModelError.notInstalled }
        return file.fileURL
    }
}
