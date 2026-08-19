# changelog

[![Keep a Changelog](https://img.shields.io/badge/Keep%20a%20Changelog-1.0.0-informational)](https://keepachangelog.com/en/1.0.0/)
[![Semantic Versioning](https://img.shields.io/badge/Semantic%20Versioning-2.0.0-informational)](https://semver.org/spec/v2.0.0.html)
![clq validated](https://img.shields.io/badge/clq-validated-success)

Keep the newest entry at top, format date according to ISO 8601: `YYYY-MM-DD`.

Categories, defined in [changemap.json](.github/clq/changemap.json):

- *major* release trigger:
  - `Changed` for changes in existing functionality.
  - `Removed` for now removed features.
- *minor* release trigger:
  - `Added` for new features.
  - `Deprecated` for soon-to-be removed features.
- *bugfix* release trigger:
  - `Fixed` for any bugfixes.
  - `Security` in case of vulnerabilities.

## [1.0.1] - 2026-08-19

### Fixed

- The message shown when no changelog entry is found names the pull-request *body* as the
  route, which is where the section belongs. It previously said "the pull request", which
  reads as though a section anywhere on it would do.
- A feature-build marker is rejected unless it is `<user>-<ticket>` shaped. The marker is
  author-written and becomes part of a version, so one containing a space or a slash used to
  yield a version no registry accepts. It also failed the publishing action's version regex,
  which produced an ordinary build and said nothing about the marker the author had written.

## [1.0.0] - 2026-08-19

### Added

- Resolves a ref's changelog manifest and reports what it says: the entry text, the
  feature-build marker it carries, the route it came by, and the pull request it was read
  from. One component answers all of them, so a build, a merge gate and an assembly can no
  longer disagree about what a branch declared.
- Resolves a ref to its pull request when the caller does not name one, which is what makes
  a marker written in a pull-request body readable from a `push`. No open pull request means
  the file is the whole manifest; more than one is an error rather than a guess.
- Treats more than one *marker* as the ambiguity, rather than more than one file. A merge
  queue stages several branches' entries side by side, and every one of them is legitimate.
