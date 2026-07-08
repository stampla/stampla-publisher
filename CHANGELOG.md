# Changelog

Notable changes to this project are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Publish service provider for Lightroom Classic 10 and later.
- Published files are named after the original's filename stem plus a
  configurable suffix (default `_lr`).
- Two folder structures per publish service: from collections
  (collection sets and collections become nested folders), or from
  catalog folders (the published tree mirrors the catalog's Folders
  panel, relative to its root folders — nothing to configure).
- Configurable on-remove behavior: move to trash (default), delete,
  or leave in place.
- Renders land under a temporary name and are moved into place, so a
  crashed render never leaves a truncated file under a published name.
- Republishing replaces the recorded file; retargeting (renamed or
  re-nested collection, renamed original, changed root or suffix) writes
  the new file and applies the on-remove setting to the old one.
- Deleting a published collection or the whole service applies the
  on-remove setting to everything recorded, after one confirmation.
- Renaming or re-nesting a collection marks its photos to republish so
  the folder tree heals on the next publish.
- Duplicate publish targets fail with an error, and files the plugin
  has no record of writing are never overwritten or removed.
- The filename suffix understands tokens: `{ext}` inserts the original's
  file extension (`{ext:lc}` / `{ext:uc}` force its case), so published
  files name their source and same-stem originals of different formats
  publish side by side. Unknown tokens abort the publish with a clear
  error.
- Changing a service's naming-affecting settings (publish root, folder
  structure, suffix) offers to mark all published photos to republish,
  so the tree rebuilds on the next publish.
