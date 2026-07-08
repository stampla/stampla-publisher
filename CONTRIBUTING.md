# Contributing

## Linting

Lua sources must pass `luacheck stampla-publisher.lrplugin` — CI
runs the same check. `.luacheckrc` also encodes what Lightroom's Lua
sandbox actually provides (for instance `os.rename` does not exist at
runtime), so treat its warnings as real errors, not style advice.

## Manual test checklist

Adobe ships no test harness for the Lightroom SDK, so publish behavior
is verified by hand against a real catalog before each release. Create
a publish service pointing at a scratch folder and run through:

Basics

- [ ] Publish a few photos; files appear under the expected folder,
      named original stem + suffix + rendered extension.
- [ ] Edit a published photo and republish; the file is replaced and
      no stray `.part` files remain.
- [ ] Remove a photo from the collection and publish; the file is
      moved to the trash (or deleted, or left, per the setting).

Layouts

- [ ] From collections: collection sets nest into folders
      (`set/set/collection`).
- [ ] From catalog folders: files land in the original's folder path
      relative to its catalog root folder, matching the Folders panel.

Retargeting

- [ ] Rename a collection: its photos are marked to republish, and the
      next publish writes to the new folder and applies on-remove to
      the old files.
- [ ] Move a collection into a different set: same.
- [ ] Change the filename suffix in the service settings: the plugin
      offers to mark everything to republish; accepting rebuilds the
      tree, with old names handled per on-remove.
- [ ] Suffix `_{ext}_lr`: a raw original publishes as `…_nef_lr.jpg`
      (extension as spelled in the original; `{ext:lc}` lowercases it),
      and a same-stem tif publishes beside it without colliding.
- [ ] Suffix with a typo'd token (`_{extt}`): publish fails up front
      with the supported-token list, nothing rendered.
- [ ] Rename an original in the catalog and republish: the published file
      follows.

Safety

- [ ] Publish two virtual copies of one original into the same target:
      the second fails with a clear error and the first file is intact.
- [ ] Put a foreign file at a photo's target path: publish refuses to
      overwrite it.

Lifecycle

- [ ] Delete a published collection: one confirmation, then the
      recorded files are handled per the on-remove setting.
- [ ] Delete the publish service: same, across all its collections.
- [ ] With on-remove set to leave: all of the above leave files in
      place.

Most development happens on macOS, so a verification pass on Windows
is especially welcome.
