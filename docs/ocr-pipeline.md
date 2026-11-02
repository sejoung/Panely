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

`ComicOCREngine` shares sessions across books, uses four CPU threads for line
detection and two for reading, and releases sessions after two idle minutes.
Japanese crops are encoded in batches of at most eight. PP readers also group
up to eight lines of exactly the same input width. Each crop keeps its original
padding and resolution, and results are restored to the original line order
before publication. CTC decoding scans the output without allocating a class
array at every time step. PP-OCR uses BGR normalization, DB
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

Opening the translation panel prepares an already installed Gemma model on
its own executor. This does not download models or start a translation job.
Preparation is shared with jobs: repeated preparation uses the loaded runtime.
Gemma stays loaded for ten idle minutes (previously two), allowing short reading
breaks and repeated panel openings to reuse it. Model removal explicitly unloads
it. This retains about 3.5 GB of mapped model memory longer; it moves cold setup
earlier when the panel opens, but cannot eliminate a cold load when translation
starts immediately. Runtime logs separate backend initialization, model loading,
context creation and the short generation warm-up.

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

A local check on four 1500×2109 Korean comic pages (2026-11-02, two passes,
optimized Debug) measured the following. This times OCR only, without image
decoding, RT-DETR or translation. Output text digests and region counts matched
between devices on these four pages; this is not an accuracy assessment.

| Measurement | CPU (s/page) | Core ML (s/page) |
| --- | ---: | ---: |
| Second pass, full OCR | 0.512–0.768 | 0.740–0.983 |
| First real page, new OCR sessions | 0.717 | 6.809 |

CPU line detection took 0.469–0.519 s/page, while reading the 2–15 detected
lines took 0.042–0.295 s/page. Full-page line detection was the larger cost on
these samples. These initial measurements used two detector threads and
one-line recognition.

A follow-up on 24 evenly spaced Korean pages from the same book compared
two passes through each configuration. All 192 OCR runs returned identical
text, geometry and region ordering. Average page times (including session
creation on each configuration's first page) were:

| Detector threads / recognition batch limit | Mean OCR (s/page) |
| --- | ---: |
| 2 / 1 (reference) | 0.793 |
| 2 / 8 | 0.768 |
| 4 / 1 | 0.643 |
| 4 / 8 (new default) | 0.631 |

The combined change reduced mean OCR time by about 20% on this local sample.
This is an OCR-only result, without simultaneous Gemma generation; full-book
translation speed and quality on other books/hardware are not established by
this comparison. The resolution cap remains 2400. Detailed timings showed
model inference dominating line detection (about 0.43 s with two threads),
with preprocessing around 0.03 s and postprocessing around 0.003 s.

To repeat with local images, put them in a directory readable by the sandboxed
Debug test host (for example its Caches directory), then run:

```sh
TEST_RUNNER_PANELY_OCR_PROFILE_DIR=/path/to/pages scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
TEST_RUNNER_PANELY_OCR_PROFILE_DIR=/path/to/pages PANELY_OCR_LINE_DEVICE=coreml scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
TEST_RUNNER_PANELY_OCR_PROFILE_DIR=/path/to/pages TEST_RUNNER_PANELY_OCR_PROFILE_THREADS=2,4 scripts/test-ocr.sh SWIFT_OPTIMIZATION_LEVEL=-O
```

The optional real-page test assumes Korean input and prints timings, counts
and text digests, without recognized text or image paths. To compare detector
resolution caps in the same run, also set
`TEST_RUNNER_PANELY_OCR_PROFILE_LIMITS=2400,1920,1600,1280`. Each cap gets fresh
sessions and two passes, for both single-line and batched reading.
`matchesBaseline` compares recognized strings with the first cap. Batched
results are asserted equal to single-line results, including region geometry;
thread comparisons also assert equality at the first cap. The normal pipeline
retains the 2400-pixel cap.

On the four Korean pages above, a 1600-pixel cap reduced second-pass OCR to
0.340–0.530 s/page, but two pages' text differed from the baseline and one
returned fewer regions. A 1280-pixel cap changed all four pages' text. These
differences are not scored against a human transcription, so lower resolution
is not adopted as the default based on this speed test.

Production `Comic OCR completed` info logs record image dimensions, line count,
thread/batch settings, line-detection time (preparation, session loading,
inference and postprocessing separately) and reading time. Translation job `analysisWaitSeconds`
measures exposed pipeline waiting, including decoding/detection/grouping and
queueing; it is not a direct measurement of OCR compute time.

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
