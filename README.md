# synthesize-changelog-entry

Resolves a ref's changelog manifest and reports what it says.

A change arriving at a pipeline declares two things about itself: **what changed**, and
**whether it is a feature build**. That declaration may be written in either of two places —
a file under `.changelog/`, or a `## CHANGELOG` section in the pull-request body.

Several components need to know what it says: the build, to decide whether to publish a
feature version; the merge gate, to require an entry and to refuse a pull request still
marked as a feature build; assembly, to write the release block after merge.

This action exists so that they **ask** rather than each **decide**.

## Why one component

Before this action, each of those components read the manifest itself: three frontmatter
parsers across two repositories. They did not agree, and two failures followed directly.

- **A marker written in a pull-request body was silently inert.** Nothing read it and
  nothing rejected it. An author who believed they had marked a feature branch got an
  ordinary build, an unguarded merge, and no signal either way.
- **File count stood in for marker ambiguity.** More than one file in `.changelog/` failed
  the build whether or not any of them carried a marker. That is what a merge queue produces
  *every time it batches two pull requests*, so it blocked every build in the repository
  that adopted it first — including the pull request that fixed it.

Neither is a bug you can fix once. They are what happens when several components answer the
same question separately: correcting one parser does not make the others agree.

## Usage

```yaml
- id: changelog
  uses: Arda-cards/synthesize-changelog-entry@v1
  with:
    # Optional. Unset resolves the pull request from the ref, which is what
    # makes a body marker readable from a push.
    pr: ${{ github.event.pull_request.number }}
    # Optional. A build wants the marker and tolerates no entry; a merge gate
    # and an assembly do not.
    require_entry: "false"
  env:
    GH_TOKEN: ${{ github.token }}
```

| Output | |
|---|---|
| `entry` | The changelog entry, with any marker line removed. |
| `marker` | The feature-build marker, or empty for an ordinary build. |
| `route` | `file`, `body`, or `none`. |
| `pr` | The pull request the manifest was read from, or empty. |

The job needs `pull-requests: read`, and `contents: read` for the file route.

## The rules it enforces

1. **Exactly one route.** A file and a body section together is an error — there is no
    precedence rule and no silent winner.
2. **One manifest, one marker.** Checked on the marker as well as on the entry, since a file
    carrying frontmatter but no entry would otherwise slip past.
3. **Ambiguity is more than one marker, not more than one file.** A queue batch stages
    several branches' files side by side and every one of them is legitimate.
4. **A ref with no open pull request has no body.** The file is the whole manifest. More than
    one open pull request is an error rather than a guess.
5. **The marker never reaches `CHANGELOG.md`.** It is read and stripped in the same place, by
    both routes, because it is configuration for the pipeline rather than a release note.

## Comments come to whoever reads this next

The behaviour above is not obvious from the code alone, and most of it was learned from an
incident rather than designed up front. The reasoning is kept in the source next to the line
it explains, and in the project's decision record under `queued-cicd-adoption`.
