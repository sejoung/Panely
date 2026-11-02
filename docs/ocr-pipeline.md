# Comic OCR on macOS

The normal pipeline is RT-DETR balloon/text detection (the existing Core ML
GPU model), PP-OCRv5 mobile line detection, manga-ocr int8 for Japanese text
crops, or PP-OCRv5 mobile recognition for Chinese, English and Korean. ONNX
Runtime 1.24.2 runs in process. The small OCR readers and line detector use CPU
by default; the DirectML device split from Windows is not assumed on Mac.

The translation download includes the same pinned ~160 MB OCR artifacts as
PanelyWindows. `ComicOCRModels.swift` records revision, size and SHA-256 for
every file. Installation verifies both size and hash. Upgrading an existing
Gemma installation downloads only missing files; interrupted packs can resume
without downloading files already verified. Settings can remove a partial pack.
Models are stored in Application Support, not Caches.

`ComicOCREngine` shares sessions across books, bounds CPU execution to two
threads per session and releases sessions after two idle minutes. Japanese crops
are encoded in batches of at most eight. PP-OCR uses BGR normalization, DB
connected-component line finding and CTC decoding with language dictionaries.
Vertical Chinese/Japanese lines rotate counterclockwise for PP-OCR. Japanese
glyph size and direction come from detected text lines. Tall images are tiled
with overlapping seams, preserving the existing page/strip ownership rules.

Complete balloon containers are kept together before publication. OCR batches
stream through `PageAnalyzing` to `TranslationController`: translation can start
while later balloons on the same page are still being read. A unit is completed
and cached only after the OCR stream finishes. Cancellation stops its producer
and pending lookahead; translation context is retained across partial batches.

Vision remains the fallback when models are missing or fail before any results
are published. A failure after partial publication fails/retries the unit rather
than mixing two engines' different balloon boundaries on the page. Normal startup
no longer compiles all five Vision language models. The fallback's first use can
still be slow. Cache revisions distinguish comic OCR from the Vision path.

## Verification

```sh
scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
PANELY_COMPARE_VISION=1 scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
PANELY_OCR_LINE_DEVICE=coreml scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
scripts/test.sh
```

The opt-in integration suite downloads the actual pinned OCR files into the
test host's cache (`panely-ocr-test-models`) and checks Japanese horizontal and
vertical text, Chinese, Korean, English, empty images and automatic language
identification. Ordinary tests never download models. `OCRBENCH` lines expose
timings and recognized text; the test pack is independent of production models.
`PANELY_OCR_ENGINE=vision` forces the old path; `comic` requires the comic pack
and propagates errors so comparisons cannot silently measure a fallback.

Observed on the development Apple Silicon Mac, optimized Debug build,
800×1000 synthetic pages, one short text area per page:

| Input | Comic OCR CPU (s) | Vision, already prepared (s) |
| --- | ---: | ---: |
| Japanese horizontal | 0.457 | 0.347 |
| Japanese vertical | 0.277 | 0.258 |
| Korean | 0.236 | 0.263 |
| Chinese | 0.233 | 0.270 |
| English | 0.223 | 0.176 |

These are smoke-test measurements, not a real-comic quality benchmark or a
general speedup claim. The first Japanese sample includes session loading;
subsequent samples reuse the line detector. A separate Core ML line-detector
run recognized the same strings but took 5.797 s on its first sample and
0.308–0.475 s afterwards, compared with CPU's 0.222–0.486 s in the corresponding
CPU-only run. CPU is therefore the default. Core ML remains available for
comparison on other hardware; its session creation can fall back to CPU.

Fast tests cover CTC layouts (including long English lines), blank-separated
repeated characters, manga token termination and normalization, DB thresholding,
crop clipping, BGR/grayscale preprocessing, rotation, cancellation, complete
container batching, partial-download upgrades/removal, and starting translation
before the rest of a page's OCR completes. Recognition quality on real comic
pages still needs a representative golden set.

Sources: [PanelyWindows OCR adapters](https://github.com/sejoung/PanelyWindows/blob/main/src/Panely.Core/Translation/ComicOcrEngines.cs),
[model pins](https://github.com/sejoung/PanelyWindows/blob/main/src/Panely.Core/Translation/ModelManifest.cs),
[manga-ocr](https://github.com/kha-white/manga-ocr),
[PP-OCR ONNX files](https://huggingface.co/ogkalu/ppocr-v5-onnx),
[ONNX Runtime Core ML provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html).
