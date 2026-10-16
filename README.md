# CatSystemKit

Shiori's CatSystem2 engine (NEKOPARA Vol. 3): KIF archives, HG-3 images, kcScript and the FES screen scripts, in Swift, and the E-mote character renderer (PSB models on Metal) that [KiriKit](https://github.com/OWCramer/KiriKit) uses too. Part of [Shiori](https://github.com/OWCramer/shiori).

It plays games you own; no game content is included.

- `Sources/CatSystemKit`: the formats, the interpreter, the stage and the E-mote renderer.
- `cs2-cli`: lists archives, dumps scripts and exports images on the Mac.

```sh
swift build
swift test
```

## Licence

CatSystemKit's own code is under the [Mozilla Public License 2.0](LICENSE). `KIFArchive.swift` and `HGImage.swift` follow GARbro's format code (MIT, morkt), credited in their headers.
