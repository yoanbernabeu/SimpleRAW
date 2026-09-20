# SimpleRAW

A native macOS app to develop RAW photos, manage a catalog and back everything up to S3.
Open source, minimalist, built on Apple's own RAW engine (`CIRAWFilter`) and Metal.

> A library (import, ratings, flags, labels, keywords, albums, smart albums, filters) and a
> develop view, in one window. The develop view works in real time: light and color sliders,
> point curves, HSL, color grading, vignetting, lens corrections, local adjustments (gradient,
> radial, brush and masks the machine finds), spot removal, crop / straighten / keystone,
> 100 % zoom, looks, moods from `.cube` files, soft proofing, copy and paste of settings,
> export presets, batch development. The library backs itself up to any S3-compatible storage.

## Requirements

- macOS 15 or later, Apple Silicon recommended
- Swift 6 (Xcode, or the Command Line Tools alone)

## Installing

```sh
curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/SimpleRAW/main/scripts/install.sh | sh
```

That downloads the latest release, puts it in `/Applications`, and takes the quarantine flag
off it. [The script](scripts/install.sh) is twenty lines and says so itself — read it before
you run it, as you should with anything piped into a shell.

Or build it yourself, which needs no such step:

```sh
make app                    # builds .build/SimpleRAW.app
```

**Why the quarantine step.** The app is sandboxed and runs under a hardened runtime with no
escape entitlement of any kind, but it is **signed ad-hoc** — there is no Apple Developer
certificate behind this project, and notarisation needs one. So macOS marks anything
downloaded, and Gatekeeper refuses it until the mark is removed. Right-clicking the app and
choosing **Open**, once, does exactly the same thing by hand. Either way, do it only for
software you have reason to trust. An app you built yourself was never downloaded, has no
mark, and simply opens.

What the sandbox lets it reach: the network, and the files you pick. Nothing else.

## Running it from the source tree

```sh
make run                    # opens the library, ~/Pictures/SimpleRAW Library
make run FILE=photo.dng     # opens one file straight in the develop view
```

This is the unwrapped executable, outside the sandbox: it is what the benchmarks and the
scripted gestures drive, and the only way to judge responsiveness (a debug build is 500×
slower at building a lookup table). The wrapped app ignores every one of these arguments.

**Library** — import a folder or a memory card (⇧⌘I): originals are copied into the library,
never moved, and a file it already has is skipped.

| Key | Action |
|---|---|
| `0`–`5` | Rate the selection |
| `P` / `X` / `U` | Pick, reject, unflag |
| `6`–`9` | Color label (again to clear) |
| ← → | Move the selection; ⇧-click and ⌘-click extend it |
| Return, or double-click | Open in the develop view |

Right-click for albums, looks, pasting settings, exporting and removing. Removed originals go
to the Trash.

**Develop** — `G` goes back to the library, ⌘[ and ⌘] step to the neighbouring photos.

| Key | Action |
|---|---|
| `\` | Compare with the unedited image |
| `Z`, or double-click | Switch between fit and 100 %; drag to pan |
| ⌘U | Auto: sets light and color from the picture itself |
| `C` | Crop, rotate and straighten |
| `M` | Local adjustments, as layers: gradient, radial and brush masks |
| ⌘Z / ⇧⌘Z | Undo / redo |
| `S` | Spot removal: click a blemish, then drag its source |
| ⇧⌘R | Reset all adjustments (double-click a slider's name to reset just that one) |
| ⇧⌘C / ⇧⌘V | Copy / paste settings (everything but crop and rotation) |
| ⌘E | Export a JPEG; hold the button to pick an export preset |
| ⌥⌘I | Show or hide the inspector |

In the curve editor, click to add a point and drag it out of the square to remove it.

Edits are non-destructive. Library photos keep theirs in the catalog; a file opened from
outside the library gets a `photo.dng.simpleraw.json` next to it.

## Backup

In Settings (⌘,), point the app at any S3-compatible storage: AWS, Scaleway, OVH, Backblaze
B2, Cloudflare R2, MinIO… Keys are kept in your Keychain. The library then backs itself up
after an import and when you come back from the develop view: originals, exports, and the
catalog with every rating, keyword, album and edit. Nothing is ever deleted from the bucket.

What to know before relying on it:

- **The bucket must exist**: the app never creates one. Keep it private.
- **Nothing is encrypted by the app.** Whoever holds the keys, and your provider, can read the
  photos and the catalog. Turn on server-side encryption, and versioning or Object Lock.
- **Give the app a key that cannot delete.** It needs `s3:ListBucket` on the bucket, and
  `s3:PutObject`, `s3:GetObject` and `s3:AbortMultipartUpload` on `bucket/folder/*`. Nothing else.
- Every object is sent with its SHA-256 (`x-amz-meta-sha256`). A restore checks each original
  against the catalog, which detects damage, not tampering: the catalog comes from the same
  bucket.
- Redirects are refused: if the server answers with one, fix the endpoint or the region.

## Looks and export presets

A look is a JSON file in `~/Library/Application Support/SimpleRAW/Presets`. Save one from the
Looks panel, or write it by hand — a partial document is enough, and the file name is the
name of the look:

```json
{ "contrast": 20, "shadows": 35, "vibrance": 15 }
```

A look only replaces the groups of settings it mentions (light, curve, white balance, color,
HSL, color grading, detail, optics, geometry). "Camera match", built in, brings Apple's
neutral rendering close to a Ricoh GR III JPEG.

## The command line tool

```sh
make build

# What the engine knows about a file
.build/debug/simpleraw info photo.dng

# Develop with options…
.build/debug/simpleraw develop photo.dng -o photo.jpg \
    --exposure 0.5 --highlights=-60 --shadows 50 --contrast 20 --vibrance 25

# …or from a JSON adjustments file (a preset is just a partial document)
.build/debug/simpleraw develop photo.dng --adjustments look.json --long-edge 2048

# Develop a whole shoot: each photo's saved edits, a look on top, an export preset
.build/debug/simpleraw batch shoot/*.dng --preset "Camera match" --export "Web 2048" -o out/

# What looks and export presets exist
.build/debug/simpleraw presets

# Extract the JPEG embedded by the camera, to compare renderings
.build/debug/simpleraw preview photo.dng
```

Sliders range from -100 to +100 (0 to 100 for sharpness and noise reduction); exposure is
in EV. Run `simpleraw develop --help` for the full list.

## Supported files

RAW files first: whatever `CIRAWFilter` supports on your macOS version (900+ models), including any camera
that shoots DNG. The reference camera for this project is the Ricoh GR III. JPEG, HEIC, TIFF
and PNG files open, import and develop through the same pipeline, minus what only a RAW
decoder can do (its sharpening and noise reduction, the white balance eyedropper).

## Development

```sh
make test       # needs nothing but the repository
make test-s3    # also runs the backup against a throwaway MinIO, in Docker
make bench      # replays every continuous gesture; fails over the 16 ms frame budget
make gestures   # drives the real app with real mouse events, and checks what answers
make app        # the bundle that ships: sandboxed, hardened, ad-hoc signed
```

End-to-end tests need a DNG in `Samples/` (git-ignored) and are skipped without one. A CC0
sample is available from
[raw.pixls.us](https://raw.pixls.us/data/Ricoh/GR%20III/R0000357.DNG).

## License

[MIT](LICENSE)
