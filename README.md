# Stampla Publisher

Publish photos and videos from Lightroom Classic into a plain folder
tree — part of the [Stampla](https://github.com/stampla/stampla)
toolset.

Point a publish service at a folder and pick a folder structure:
from collections — a set `2026` holding a collection `2026-07`
publishes into `<root>/2026/2026-07` — or from catalog folders, where
the published tree mirrors the Folders panel with no configuration at
all. Either way, every published file is named
after its master with a configurable suffix. The suffix understands
`{ext}` — the master's extension, with `{ext:lc}` / `{ext:uc}` case
modifiers — so a published file can name its own source:

```
suffix _lr:        20260703_150727_9b677b64.nef  ->  <root>/2026/20260703_150727_9b677b64_lr.jpg
suffix _{ext}_lr:  20260703_150727_9b677b64.nef  ->  <root>/2026/20260703_150727_9b677b64_nef_lr.jpg
```

With the extension in the name, a raw capture and the retouched tif
beside it publish as distinguishable files instead of colliding.

Republishing an edited photo replaces its file; removing a photo from
a collection moves its file to the trash (configurable: trash, delete,
or leave). The plugin never touches a file it did not write.

## Status

Early development. The walking skeleton publishes, republishes and
removes; expect rough edges beyond the happy path.

## License

MIT — see [LICENSE](LICENSE).
