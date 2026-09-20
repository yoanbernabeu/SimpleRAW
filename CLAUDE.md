# SimpleRAW

Native macOS RAW developer, catalog and S3 backup.

## Conventions

- **Language**: code, identifiers, comments, commit messages, CLI/UI strings and
  documentation are in English.
- **TDD**: write the failing test first, watch it fail, then implement. A bug fix starts
  with a test that reproduces it.
- **DRY**: one source of truth per fact (neutral slider values live on `Adjustments`
  properties, slider ranges in `Slider`, measurements in the `PixelProbe` test helper).
- **SOLID**, pragmatically: one responsibility per type, extend by adding types rather than
  editing existing ones, inject collaborators. No protocol for a single implementation
  unless a test needs the seam.

## Commands

```sh
make build     # debug build
make test      # full suite, under a memory guard (handles the Swift Testing path when Xcode is absent)
make test-clone  # the suite as a fresh clone runs it, without the git-ignored samples
make bench     # replays continuous gestures in release; fails over the 16 ms frame budget
make gestures  # drives the real app with real mouse events; fails when a gesture changes nothing
make app       # the app as it is distributed: a real bundle, sandboxed, hardened, ad-hoc signed
make test-s3   # same as test, plus S3 integration tests against MinIO in Docker (quay.io/minio/minio)
make release   # optimized build
make run FILE=Samples/photo.dng [LOOK=look.json]   # launch the app, optionally on a file
.build/debug/simpleraw --help
.build/debug/simpleraw noise Samples/photo.DNG   # what can be done about the noise in it
```

Tests use Swift Testing (`import Testing`), not XCTest.

## Architecture

- `Sources/RawEngine` — UI-free engine.
  - `RawSource` opens a photo and picks its `PhotoDecoder` on the type of the file:
    `RawDecoder` (`CIRAWFilter`) for RAW, `RenderedDecoder` for JPEG, HEIC, TIFF and PNG.
    Everything after decoding is the same pipeline. `RawInfo.isRaw` and `capabilities` say
    what the interface may offer.
  - `Pipeline/` — a `DevelopPipeline` is an ordered list of `PipelineStage`s. **A new
    treatment is a new stage** (plus its entry in `DevelopPipeline.standard`), never an
    edit to `RawSource` or to another stage. A stage returns its input untouched when its
    settings are neutral.
  - Per-pixel color work that stock filters do not cover goes through lookup tables built
    from pure Swift functions (`Curve` → `CurvesStage`), not custom Metal kernels: pure
    functions are trivial to test, and a lookup table needs no compiler.
  - The one exception is **geometry that moves each pixel by a different amount** — barrel
    distortion — which no stock filter and no lookup table can express. It has a Core Image
    kernel in `Sources/RawEngine/Kernels/*.ci.metal`, compiled by the `MetalKernels` plugin
    through `scripts/build-metallib.sh`. The kernel is **optional at build time**: without
    Xcode's Metal toolchain the script writes an empty library, the build goes through,
    `MetalKernels.isAvailable` is false, the stage passes the picture on untouched and
    `SliderSpec.all(in:)` does not offer the slider. Add a kernel only for something of that
    kind, and keep the same fallback.
  - `Adjustments` — versioned, Codable settings document. Partial JSON is valid (presets).
    Bump `currentVersion` and migrate when a field changes meaning.
  - `Renderer` — owns the `CIContext`, exports.
  - `PhotoCredits` — what one picture says about itself: title, caption, author, copyright and
    keywords, as opposed to what the camera wrote. `Renderer.write` and `BatchJob` take it (no
    `keywords:` parameter), it is written whatever `ExportOptions.metadata` keeps of the rest,
    and its author and copyright beat the export preset's, which signs a whole batch. Blank is
    nothing: `PhotoCredits.nonBlank` is the one rule, used by the fields and by the catalog.
  - `Curve`, `HSLTransform`, `ColorGradingTransform`, `Geometry`, `Perspective`, `CropRect` — pure models
    and math, no Core Image: this is where behavior is specified and tested. Their stages
    (`CurvesStage`, `HSLStage`, `ColorGradingStage`, `GeometryStage`) only hand them to the GPU.
  - Stage order is part of the contract: `VignettingStage` first (linear sensor data), then
    `LensCorrectionStage` (fringes and the keystone correction, measured into that position: a
    homography behind the blurs makes Core Image keep a new set of them every frame of a drag —
    8 GB in two seconds; it follows that masks and spots sit on the *corrected* picture), then
    `SpotRemovalStage` (everything else sees clean pixels), global tone, then
    `LocalAdjustmentsStage` (looks apply on top of local work), creative color, `LUTStage`
    (a mood goes over a finished picture), and `GeometryStage` last (everything else is
    defined on the uncropped frame).
  - A mood is a `.cube` file: `CubeLUT` parses and samples it (pure, and where every rule
    about the format is decided), `LUTLibrary` is the folder it is read from, and
    `Adjustments.lut` names it — the table is never stored in the document. `CIColorCube`
    takes 64 nodes per axis, so a LUT of 65 is resampled; the amount is a blend, not a
    second table.
  - `Local/` — `Mask` (linear, radial, brush), `LocalSettings`, `LuminanceRange` (the tones a
    layer is held to; neutral is stored as none and costs nothing), `Spot` (a point, or the
    line drawn along a wire: same offset from end to end, and its mask is a brush stroke). Positions are
    `NormalizedPoint`s in the original, uncropped, unrotated frame (origin top-left), which
    is also what local tools display. `LocalSettings.apply` reuses the global stages so
    that local sliders behave like global ones. `RecentValuesCache` backs both lookup
    tables and painted masks.
  - A mask the machine finds (`Mask.detected`) stores **what was asked for, never the
    pixels**: a sort, an instance, and a `UUID` made once. That id is the key into
    `MaskRasterStore`, which `Mask.image(in:)` reads — so a mask computed elsewhere and
    arriving later needs no change to a signature that is pure and synchronous, and no
    identity of the photo. **No raster yet means a black mask**, so the layer changes nothing
    and the picture never flickers; that rule is what the whole arrangement rests on. It takes
    the brush like a painted mask (`corrections`), added by the maximum and removed by
    multiplying by the inverse, and what is painted shows before Vision has answered.
    `MaskFinder` (SimpleRAWUI) is what fills the store, with a decoder of its own.
  - `Presets/` — `AdjustmentGroup` and `Adjustments.apply(_:groups:)` are the one mechanism
    behind looks, copy/paste and batches. **A new field of `Adjustments` must be added to a
    group** (a test fails otherwise). `JSONFileStore` is a folder of JSON files plus
    read-only built-ins; `SidecarStore` keeps each photo's edits next to it.
  - Presence (dehaze's contrast, clarity, structure) is one stage, `LocalContrastStage`:
    every scale shares one round trip to display-referred values. One-gesture tools such
    as Enhance are folded into the effective settings (`foldingEnhance`) before the
    pipeline runs: never add a stage that re-runs what another stage already does.
  - `SoftProof` shows a picture as a paper would print it, and is a **viewing condition**:
    never in `Adjustments`, never in an exported file. The round trip goes through ColorSync
    one colour at a time and is baked into a `ColorCube` — `matchedFromWorkingSpace(to:)`
    answers nothing for a CMYK profile, and in floating point a round trip is lossless anyway,
    so neither shows what a print loses. Building the table costs a few hundred milliseconds:
    once per profile, off the main actor.
  - `NoiseReport` answers "is there noise here worth acting on" by measuring, not by reading
    code: the same file rendered at each end of a setting, and the mean distance between the
    two. Half a level out of 255 (0.002) is the line below which a difference is not one.
    `simpleraw noise <file>` prints it. On a GR III at ISO 100 and 400 every noise setting
    lands at 0.0007 against 0.022 for sharpening — nothing to act on, and no file in
    `Samples/` goes higher, which is why the denoising model question is still open.
  - `HistogramAnalyzer`, `PreviewScale`, `ExposureFormat` — shared by every front end.
- `Sources/Catalog` — the library, on the system SQLite (`import SQLite3`, no dependency).
  `Database` is the only file that speaks SQLite; `PhotoCatalog` the only one that writes
  SQL, always with bound parameters. Migrations are append-only. `Library` is a folder
  (originals, catalog, previews) addressed by relative paths. `Importer` and
  `ThumbnailStore` take what they cannot do in a test (reading RAW metadata, rendering) by
  injection.
  - The title, caption, author and copyright of a photo are columns, read off the row into
    `Photo.credits`, because they belong to one picture; keywords have tables of their own,
    because they are shared and counted. `PhotoCatalog.credits(for:)` is the two put together
    — the value an export writes.
- `Sources/Backup` — `SigV4Signer` (pure), `S3Client`, and `LibraryBackup`, which only knows
  an `ObjectStore`. Backup scenarios are written once (`BackupScenarios`) and run against
  `InMemoryObjectStore` in `make test` and against MinIO in `make test-s3`. Keys live behind
  `CredentialStore`: the Keychain in the app, memory in tests. Never write a key to a file
  or a log.
  - A catalog that came from elsewhere (a restore) goes through
    `PhotoCatalog.validateForeignCatalog(at:)` before it is opened: the schema must be exactly
    what the migrations produce, triggers included. `Library.isConfined(relativePath:)` is the
    one rule about paths, `ContentHash` the one hashing utility. `PhotoCatalog.revision`
    (table `meta`, maintained by triggers) says whether anything changed without a `VACUUM`.
    `synchronous = FULL` is deliberate. Operations by ids run in batches of 500
    (`forEachBatch`). Bump `ThumbnailStore.renderVersion` when a stage renders differently.
  - `S3Transport` is the one `URLSession`: ephemeral, no redirects, bounded responses; never
    `URLSession.shared`. Values typed or read from disk enter through `S3Naming` and
    `S3Configuration.validated()`. Object keys are built by path components, the catalog is
    uploaded last, and the app never creates a bucket (`createBucketIfNeeded` is for tests).
    `StubServer` (a `URLProtocol`) serves the tests: nothing leaves the machine.
- `Sources/simpleraw` — CLI over the engine and the catalog.
- `Sources/SimpleRAWUI` — the app, as a library so that it is testable.
  - `AppSession` owns a `LibrarySession` and a `DevelopSession` and says which is on screen.
    `LibrarySession` is to the grid what `DevelopSession` is to the canvas.
  - The histogram (`HistogramWorker`) and the full-size picture the 100 % view pans over
    (`ZoomCacheWorker`) are computed by actors that own a decoder of their own; the session
    shows their last result. Run `make bench` after touching the pipeline or the session.
  - Nothing heavy on the main actor, ever: fluidity is a hard requirement, and `make bench`
    is what holds it — a frame that renders the canvas has 16 ms.
    Imports, exports and thumbnails run detached and report back.
  - `DevelopSession.tool` says what the canvas is used for (`none`, `crop`, `level`, `local`,
    `spots`, `whiteBalance`); each tool decides which geometry the canvas shows. Tool logic
    lives in `DevelopSession+LocalTools.swift`. `level` is a gesture inside the crop tool:
    `isCropping` covers both, and putting it down goes back to `crop`, never to nothing.
  - Undo: anything that changes `adjustments` from a button or a menu goes through
    `DevelopSession.perform { }`, which makes it one undo step. Continuous gestures need
    nothing: a step is taken when edits settle, with the autosave. Applying a look is the one
    exception: it opens an amount (`dosedLook`, `setLookAmount`) and settles like a gesture,
    so that picking a look and dialling it back is one step. Every amount is recomputed from
    `lookBase`, never from what is on screen, or the look piles onto itself.
  - `LibrarySession` reads the catalog off the main actor, with a generation token that drops
    stale answers: **a test that changes the filter, the sort, the source, keywords, a look or
    removes photos awaits `session.settle()`**. Ratings, flags and labels stay synchronous, in
    place. The loupe (Space) is its state too; `LoupeLoader` shows the embedded preview first.
  - Under the grid, the keywords (⌘K) and what is said about the selection (⌘I) are read from
    what is already at hand: `shownCredits` off the rows of the grid, the keywords by a query,
    both showing only what the selection shares. A title names one photo and the panel offers
    it for one; an author signs a shoot (`setSignature`, which leaves each title alone).
  - Comparing (C) is the loupe at two: the photo being judged is the **selected** one, so
    rating, flagging and labelling know nothing about it. The filmstrip under the develop
    view (⌥⌘F) is the grid as it stands; it is also what decides whether thumbnails are
    decoded while a photo is open (`AppSession.updateThumbnailWork`).
  - What a batch cannot do with a look gets its own job: `autoToneSelection()` analyses one
    photo at a time off the main actor, with progress and cancellation, and the analysis is
    injected like the import's metadata reading, so its tests decode no RAW.
  - `ThumbnailLoader`: one `ThumbnailSlot` per cell, asked for in `onAppear`, given back in
    `onDisappear`. Never read `photo.adjustments` while drawing a cell (it decodes JSON):
    `ThumbnailLoader.key(for:)` names a thumbnail from the row's fingerprint.
  - Imports and exports report progress through an `AsyncStream` read by the `@MainActor`
    function itself, never one `Task { @MainActor … }` per step; both can be cancelled.
  - Backup settings live **in the library** (`BackupSession.settingsFile(in:)`), never global:
    two libraries have two destinations, and that is what lets the location be changed.
  - `BackupSession` reads the Keychain only for a run, a test or a restore, in a detached
    task: never at init, never from a `body`. Keys are filed under the host and the bucket
    they were entered for. Automatic requests go through `backUpSoon()`, paced by
    `BackupPacing` and skipped when `PhotoCatalog.revision` has not moved; "Back Up Now" is
    never paced. One more long job is one case of `BackupSession.Job`. A new provider is a
    case of `BackupProvider`; sentences of reports live in `BackupSummary`.
  - `AppCommands` is the menu bar: everything the keyboard does is in it. Single keys are
    `KeyRouter`'s and are written in the menu titles, never declared as key equivalents.
  - A panel changes `adjustments` as a step of its own through `\.discreteEdit` (reset
    buttons, checkboxes, typed values). The inspector and the canvas keep in step through
    `InspectorLayout.tool(whenShowing:current:)`.
  - Looks are thumbnails of the open photo (`LookPreviewWorker`), made once edits settle and
    only while the panel is on screen; `previewedPreset` tries one on the canvas.
  - `DevelopSession` (`@Observable`, `@MainActor`) is the only state. Views read and write it
    and hold no logic of their own; anything worth testing lives in the session or the engine.
  - `InspectorLayout` says which panel lives in which of the four tabs; a test fails if a
    panel is in none. One panel is open per tab. Visual constants live in `Theme`, and
    every slider is a `ValueSlider`: do not reach for a stock `Slider` or a literal color.
  - `SliderSpec.all` describes the inspector declaratively. **A new slider is a new entry**
    there, not a new view; `SliderSpecTests` then covers it automatically.
  - Coordinate conversions and gesture arithmetic live in pure, tested types (`FitGeometry`,
    `ZoomGeometry`, `SliderGeometry`, `CropHitTest`, `GridLayout`, `LibraryKeyMap`,
    `ColorWheelGeometry`, `CurveChannel`); gesture handlers only call them. `FitGeometry` is
    shared by the Metal view and the crop overlay so that the two line up.
  - `MetalImageView` renders a `CIImage` straight to an `MTKView` drawable, on demand only.
    The preview is decoded at view resolution (`PreviewScale`), never at full size.
- `Sources/SimpleRAWApp` — the `@main` entry point and nothing else. It runs unbundled from
  SwiftPM for development (`make run`, `make bench`, `make gestures`: responsiveness can only
  be judged in release, and those drive the bare executable). `make app` wraps the same
  executable in the bundle that ships: `scripts/make-app.sh` builds `Info.plist` and the
  entitlements from `simpleraw plist`, never from a copy, so the file types the Finder offers
  the app for are `Importer.importedTypes` itself (`AppBundleTests`). The resource bundle
  carrying the Core Image kernels goes in `Contents/Resources`, and `make-app.sh` stops if the
  build produced none: an app that ships without it offers no distortion slider, which is the
  engine keeping its promise and not something to find out from a user.
  - **The wrapped app is sandboxed**, hardened, with no escape entitlement, and that changes
    two things. A path carries no right to open anything, so the library is kept as a
    security-scoped bookmark (`LibraryLocation`: renewed when stale, given up when it no
    longer resolves, given back when another is chosen). And a photograph outside the library
    cannot have its settings written beside it, so they go to
    `Application Support/SimpleRAW/Edits` under a `PhotoFingerprint`, with what an earlier
    version wrote beside the photograph still read until there is an answer of its own.
  - The wrapped app answers **no launch argument** (`LaunchArguments.isSandboxed`).
- `Tests/TestSupport` — `PixelProbe`, `Sample` (the DNGs of `Samples/`) and `TestPhoto`
  (generated photos, for what does not need a RAW file), shared by the test targets.

## Testing rules

- Stages are tested on synthetic swatches (`PixelProbe.swatch`), so they run anywhere.
- Anything that writes files takes its folder by injection and is tested in a temporary
  one (`Sandbox` for sessions). `DevelopSession()` persists nothing unless given a
  `SidecarStore`: tests must never leave sidecars in `Samples/`. When driving the real app
  from a script, clean up the `*.simpleraw.json` it writes.
- `Samples/` is git-ignored and meant to be dropped into: tests taking `Sample.all` run
  against every DNG there, so a file that misbehaves becomes a regression case. Because of
  that, **`Sample.all.first` is whatever sorts first, not the reference photograph**: a test
  or a bench that asserts a size, a camera or a timing asks for `Sample.reference` and skips
  without it. `Sample.url` and `TestPhoto.url` are for "any real photo".
  Reference sample: <https://raw.pixls.us/data/Ricoh/GR%20III/R0000357.DNG> (CC0).
  A noisy one, for anything about denoising, since the reference holds no noise:
  <https://raw.pixls.us/data/Canon/PowerShot%20SX100%20IS/CRW_0964_01.DNG> (CC0, ISO 800 on a
  compact sensor).
- Assert on measured pixels, not on filter parameters.
- A test calls the method a gesture calls, which says nothing about whether the gesture
  arrives. `make gestures` is the other half: the app posts `NSEvent`s into its own window
  and checks what the session holds afterwards (`GestureScript.all`, one entry per gesture;
  `MousePath` for the arithmetic, tested on its own). **A new on-canvas tool or overlay gets
  an entry there**, and the view it is drawn in says where it is with `.gestureTarget(_:)`.
  It found the level tool answering only in a band down the middle of the canvas.

## Gotchas

- **Core Image holds colour premultiplied by alpha.** A part of a picture kept at alpha zero
  reads as black whatever its colour, and parts added together add their alphas: recombining
  three channels with `additionCompositing` gave first a black picture, then one divided by
  three. Channels are put back together with `maximumCompositing` — each part is zero outside
  its own channel, and the alpha of the result stays one (`LensCorrectionStage.deFringed`).
- **Never scale an infinite Core Image generator down** (gradients, `CIImage(color:)`,
  `CIRandomGenerator`). Core Image renders the large version before reducing it: a radial
  mask drawn 1000 px wide and scaled to a disc of a few pixels asked for ten gigabytes a
  second, and macOS rebooted rather than kill the process (three times). Draw a generator
  at its final size, or `cropped(to:)` it before any transform. Regression test:
  `aSmallDiscIsACheapMask`.
- **Always run tests and benches through `make`** (`make test`, `make bench`), or prefix a
  filtered run with the guard: `.build/memory-guard 8 swift test --filter Name`. The guard
  kills the run over a memory limit. `MemoryFuse` does the same from inside the app, the
  CLI and the tests. A new bench renders real photos through `RawSource`, as
  `FluidityBenchmarks` does, never a synthetic generator straight to a Metal texture.

- `CIToneCurve` evaluates its points in perceptual space already. Do not wrap it in a
  linear ↔ sRGB conversion (regression test: `contrastPivotsAroundPerceptualMidGray`).
- `CIRAWFilter` also opens JPEG, TIFF, PNG and HEIC files, which is undocumented: never let
  it claim a file by accepting it, choose the decoder on the file's type.
- `CIRAWFilter` ignores the DNG `BaselineExposure` tag and uses its own per-camera value.
  `RawSource` applies the tag itself: shots taken with Ricoh's highlight correction carry
  +1 EV there and otherwise render a stop too dark (test: `neutralRenderMatchesCameraExposure`).
- `CIRAWFilter.previewImage` is not oriented, unlike `outputImage`.
- `CIRAWFilter` reports lens correction as unsupported for the Ricoh GR III: distortion and
  vignetting correction will have to be our own stage.
- **An `NSEvent` handed to `NSApp.sendEvent` arrives; one posted to the queue waits for the
  app to be the active one**, and whether a process started from a terminal may come to the
  front is not ours to decide. A scripted gesture that posts passes or fails by the weather.
- The inspector remembers its tab and its open panel between launches (`InspectorLayout.tabKey`,
  `openPanelsKey`): a script that presses a slider presses whatever was last left on screen
  unless it sets those first.
- Judge the app's responsiveness in release only (`make run` does). Debug builds are 500×
  slower at building lookup tables (HSL: 0.2 ms vs 100+ ms), which makes dragging an HSL
  slider crawl for a reason no user will ever meet.
- The app takes `-library path` (always use a throwaway one from scripts), `-file path`,
  `-look path`, `-crop YES`, `-zoom YES`, `-masks YES`, `-spots YES`, `-loupe YES`,
  `-library.showsFilters YES`, `-settingsTab backup`, `-inspector.tab creative`, never a bare path: AppKit turns a bare path
  into an "open document" event, and an unbundled SwiftUI app (built against the macOS 27
  SDK) then opens no window at all. Finder integration waits for the app bundle (phase 8).
- To look at the running app from a script: find its window id with
  `CGWindowListCopyWindowInfo` and `screencapture -x -o -l <id>`; it is usually hidden
  behind the terminal, so a plain full-screen capture misses it.
- Custom Metal kernels need the `metal` compiler, which comes with Xcode's Metal toolchain,
  not with the Command Line Tools alone (on recent macOS it is a downloadable component:
  `xcodebuild -downloadComponent MetalToolchain`). The build works without it — see
  `MetalKernels` — so check `MetalKernels.isAvailable` in a test before asserting on a warp.
- **`Bundle.module` ends in `fatalError`**, and it killed the installed app: opening a
  photograph asks `SliderSpec.all` whether this build can warp one, that read the resource
  bundle, and a copy where the bundle was not among the three places SwiftPM's accessor knows
  died on the main thread. Resources are found through `KernelLibrary` — a pure search, both
  bundle layouts (`Contents/Resources` and flat, which a release runner has written), an
  optional for an answer. A test fails on any `Bundle.module` in `Sources/`.
- ArgumentParser rejects `--exposure -1`; negative values need `--exposure=-1`.
