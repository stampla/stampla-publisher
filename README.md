# Stampla Publisher

Publish photos and videos from Lightroom Classic into a plain folder
tree — part of the [Stampla](https://github.com/stampla/stampla)
toolset.

Point a publish service at a folder and pick a folder layout:
collection sets and collections map to nested folders — a set `2026`
holding a collection `2026-07` publishes into `<root>/2026/2026-07` —
or the service mirrors the masters' own folder tree below a
configured source root. Either way, every published file is named
after its master with a configurable suffix:

```
20260703_150727_9b677b64.nef  ->  <root>/2026/2026-07/20260703_150727_9b677b64_lr.jpg
```

Republishing an edited photo replaces its file; removing a photo from
a collection moves its file to the trash (configurable: trash, delete,
or leave). The plugin never touches a file it did not write.

## Status

Early development. The walking skeleton publishes, republishes and
removes; expect rough edges beyond the happy path.

## License

MIT — see [LICENSE](LICENSE).
