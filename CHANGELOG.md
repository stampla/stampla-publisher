# Changelog

Notable changes to this project are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Publish service provider for Lightroom Classic 10 and later.
- Published files are named after the master's filename stem plus a
  configurable suffix (default `_lr`).
- Two folder layouts per publish service: collection sets and
  collections as nested folders, or a mirror of the masters' folder
  tree below a configured source root.
- Configurable on-remove behavior: move to trash (default), delete,
  or leave in place.
- Renders land under a temporary name and are moved into place, so a
  crashed render never leaves a truncated file under a published name.
- Republishing replaces the recorded file; retargeting (renamed or
  re-nested collection, renamed master, changed root or suffix) writes
  the new file and applies the on-remove setting to the old one.
- Deleting a published collection or the whole service applies the
  on-remove setting to everything recorded, after one confirmation.
- Renaming or re-nesting a collection marks its photos to republish so
  the folder tree heals on the next publish.
- Duplicate publish targets fail with an error, and files the plugin
  has no record of writing are never overwritten or removed.
