# SimpleRAW

**Develop your RAW photos, keep them in order, and have the whole library back itself up.**
A native macOS app, in one window, built on the RAW engine already in your Mac.

```sh
curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/SimpleRAW/main/scripts/install.sh | sh
```

macOS 15 or later. Free and open source, MIT.

---

## Developing

The picture is on the left, the tools on the right, and there is no third place to look. Every
slider moves the photograph as you drag it — the preview is decoded at the size of your screen,
not at twenty-four megapixels, which is what keeps it honest at sixty frames a second.

**The tones.** Exposure, contrast, highlights, shadows, whites and blacks. Point curves, per
channel. **Auto** (⌘U) reads the photograph and sets light and colour from what is in it, as a
starting point rather than an answer.

**The colours.** Temperature and tint, with an eyedropper for a neutral. Vibrance and
saturation. A colour mixer, band by band: hue, saturation and lightness of the reds alone, or
the blues. Colour grading on three wheels, shadows to highlights, with the balance between
them. Black and white, with the filter of your choice over it.

**Presence**, at three scales — dehaze cuts through a veil, clarity gives a flat picture its
body back, structure brings out stone, bark and fabric. Glow and grain for what a lens and a
film used to do on their own.

**The lens.** Vignetting, chromatic aberration in two directions, barrel distortion, and
defringing for the violet halo a hard edge against the sky comes back with. Keystone
correction for converging verticals, and a level tool: draw a line along a horizon and the
picture straightens to it.

**Where it matters, and not elsewhere.** Local adjustments are layers, each with a mask:
a gradient for the sky, a radial for a face, a brush for the rest. Or let the machine find the
subject, or a person, and correct what it missed with the same brush — it holds what you paint
before it has even answered. Each layer can be held to a range of tones, so a graduated filter
on the sky spares the steeple standing in it.

**Spot removal.** Click a blemish and it is gone. Drag along a wire or a scratch and the whole
line is healed at once, with the same offset from end to end — which is what makes the repair
look like a piece of the photograph rather than a row of patches.

**Looks and moods.** A look is a set of settings you can put on any photograph and then dial
back from 100 % to nothing; picking one and dialling it back is a single undo. A mood is a
`.cube` LUT dropped in a folder, applied over a finished picture.

**Crop** to any ratio, rotate, straighten, and a 100 % view to pan around in. **Soft proofing**
shows the photograph as a given paper would print it, and marks what the paper cannot reach —
a viewing condition, never something that reaches an exported file.

Every edit is non-destructive. Your originals are never written to.

## The library

Import a folder or a memory card (⇧⌘I): originals are **copied** into the library, never moved,
and a file it already has is skipped.

Then rate, flag, label, keyword, and put photos in albums — or in smart albums that keep
themselves up to date. Filter by any of it. Compare two photographs side by side (`C`), or take
one to full screen with the space bar. A filmstrip under the develop view keeps the shoot at
hand while you work on one frame.

Copy the settings from one photograph and paste them onto fifty. Export with a preset, or
develop a whole shoot in one pass.

## Backing up

This is the part most catalogues leave to you.

Point the app at any S3-compatible storage in Settings (⌘,) — AWS, Scaleway, OVH, Backblaze B2,
Cloudflare R2, MinIO, anything that speaks the protocol. From then on the library backs itself
up on its own: after an import, and when you come back from developing. Originals, exports, and
the catalogue with every rating, keyword, album and edit in it. Your keys live in the Keychain,
and **nothing is ever deleted from the bucket**.

Before you rely on it, four things worth knowing:

- **The bucket must already exist.** The app never creates one. Keep it private.
- **The app does not encrypt anything.** Whoever holds the keys, and your provider, can read
  your photographs and your catalogue. Turn on server-side encryption, and versioning or
  Object Lock.
- **Give it a key that cannot delete.** It needs `s3:ListBucket` on the bucket, and
  `s3:PutObject`, `s3:GetObject` and `s3:AbortMultipartUpload` on `bucket/folder/*`. Nothing
  more.
- Every object carries its SHA-256. A restore checks each original against the catalogue, which
  catches damage — not tampering, since the catalogue comes from the same bucket.

## Which files

RAW first: whatever your macOS knows how to read, which is some nine hundred camera models,
plus anything that shoots DNG. The camera this was built and measured against is the Ricoh
GR III.

JPEG, HEIC, TIFF and PNG open, import and develop through the same pipeline — minus the few
things only a RAW decoder can do (its own sharpening and noise reduction, the white balance
eyedropper). The app says which of those it can offer, rather than showing a slider that does
nothing.

## Installing

```sh
curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/SimpleRAW/main/scripts/install.sh | sh
```

That downloads the latest release, puts it in `/Applications`, and takes the quarantine flag
off it. [The script](scripts/install.sh) is twenty lines and says so itself — read it before
you run it, as you should with anything piped into a shell.

**Why the quarantine step.** The app is sandboxed and runs under a hardened runtime with no
escape of any kind, but it is **signed ad-hoc**: there is no Apple Developer certificate behind
this project, and notarisation needs one. So macOS marks anything downloaded and Gatekeeper
refuses it until the mark comes off. Right-clicking the app and choosing **Open**, once, does
exactly the same thing by hand. Either way, do it only for software you have reason to trust.

What the sandbox lets the app reach: the network, and the files you pick. Nothing else.

## The keyboard

**In the library**

| Key | Action |
|---|---|
| `0`–`5` | Rate the selection |
| `P` / `X` / `U` | Pick, reject, unflag |
| `6`–`9` | Colour label (again to clear) |
| Space | Loupe; `C` compares two |
| ← → | Move the selection; ⇧-click and ⌘-click extend it |
| Return, or double-click | Open in the develop view |

Right-click for albums, looks, pasting settings, exporting and removing. Removed originals go
to the Trash.

**While developing** — `G` goes back to the library, ⌘[ and ⌘] step to the neighbouring photos.

| Key | Action |
|---|---|
| `\` | Compare with the unedited photograph |
| `Z`, or double-click | Between fit and 100 %; drag to pan |
| ⌘U | Auto: light and colour from the picture itself |
| `C` | Crop, rotate, straighten |
| `M` | Local adjustments |
| `S` | Spot removal |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⇧⌘R | Reset everything (double-click one slider's name to reset just that) |
| ⇧⌘C / ⇧⌘V | Copy / paste settings |
| ⌘E | Export; hold for a preset |
| ⌥⌘F | Filmstrip |
| ⌥⌘I | Show or hide the inspector |

In the curve editor, click to add a point and drag it out of the square to remove it.

Library photographs keep their edits in the catalogue. A file opened from outside the library
keeps them in the app's own folder, under a fingerprint of the file — a sandboxed app is given
the file you picked and no right to write anything beside it.

---

## For developers

Swift 6 and SwiftPM, no dependency but Apple's own frameworks and `swift-argument-parser`.
Building needs a recent Xcode; the Command Line Tools alone are enough if you can do without
the one Metal kernel, which the build treats as optional.

```sh
make run                    # the app, from the source tree
make run FILE=photo.dng     # straight into the develop view
make app                    # the bundle that ships: sandboxed, hardened, ad-hoc signed
```

`make run` is the unwrapped executable, outside the sandbox — what the benchmarks and the
scripted gestures drive, and the only honest way to judge responsiveness, since a debug build
is five hundred times slower at building a lookup table. The wrapped app ignores every launch
argument.

```sh
make test       # the suite; needs nothing but the repository
make test-s3    # and the backup against a throwaway MinIO, in Docker
make bench      # replays every continuous gesture; fails over the 16 ms frame budget
make gestures   # drives the real app with real mouse events, and checks what answers
```

End-to-end tests want a DNG in `Samples/` (git-ignored) and skip themselves without one. A CC0
sample: [raw.pixls.us](https://raw.pixls.us/data/Ricoh/GR%20III/R0000357.DNG).

[`CLAUDE.md`](CLAUDE.md) is the map: what lives where, which rules are load-bearing, and the
gotchas that cost a day each.

### The command line

The engine is a library, and everything the app does the terminal can do too.

```sh
simpleraw info photo.dng                     # what the engine knows about a file
simpleraw develop photo.dng -o photo.jpg --exposure 0.5 --shadows 50 --contrast 20
simpleraw develop photo.dng --adjustments look.json --long-edge 2048
simpleraw batch shoot/*.dng --preset "Camera match" --export "Web 2048" -o out/
simpleraw presets                            # the looks and export presets there are
simpleraw noise photo.dng                    # what can be done about the noise in it
simpleraw preview photo.dng                  # the camera's own JPEG, to compare renderings
```

Sliders run from -100 to +100 (0 to 100 for sharpness and noise reduction); exposure is in EV.
`simpleraw develop --help` has the full list.

### Writing a look by hand

A look is a JSON file in `Application Support/SimpleRAW/Presets`. Save one from the Looks
panel, or write it yourself — a partial document is enough, and the file name is the name of
the look:

```json
{ "contrast": 20, "shadows": 35, "vibrance": 15 }
```

It replaces only the groups of settings it mentions (light, curve, white balance, colour, HSL,
colour grading, detail, optics, geometry). "Camera match", built in, brings Apple's neutral
rendering close to a Ricoh GR III JPEG.

## License

[MIT](LICENSE)
