#!/usr/bin/env bash
#
# Resolves the changelog manifest for a ref and reports what it says: the entry
# text, the feature-build marker it carries, and which route it came by.
#
# Two authoring routes are allowed and exactly one must be used:
#
#   - a `## CHANGELOG` section in the pull-request body, or in a later comment
#     by the author or an assignee, the most recent winning; or
#   - a single file under the changelog directory, named by its author.
#
# Every caller asks this one component rather than parsing the manifest itself.
# Three independent parsers is what this replaces, and they disagreed: a marker
# written in a pull-request body was read by nothing and rejected by nothing,
# and "more than one file" stood in for "ambiguous marker", which fails a build
# every time a merge queue batches two pull requests together.
#
# Inputs arrive as environment variables: CHANGELOG_DIR, PR, REQUIRE_ENTRY.

[ "${RUNNER_DEBUG}" == 1 ] && set -xv
set -euo pipefail

readonly changelog_dir="${CHANGELOG_DIR:-.changelog}"
readonly require_entry="${REQUIRE_ENTRY:-true}"
pr="${PR:-}"

fail() {
  echo "::error::${1}" >&2
  exit 1
}

# Everything under a `## CHANGELOG` heading, up to the next heading of the same
# level or the end of the text.
extract_section() {
  awk '
    /^##[[:space:]]+CHANGELOG[[:space:]]*$/ { capturing = 1; next }
    capturing && /^##[[:space:]]/           { capturing = 0 }
    capturing                               { print }
  '
}

# Reads to end and prints the first match rather than quitting on it. An early
# exit closes the pipe under the producer, and `set -o pipefail` then kills the
# script with no diagnosis at all.
marker_value() {
  awk '
    v == "" && match($0, /^feature-build:[[:space:]]*/) {
      v = substr($0, RLENGTH + 1)
      gsub(/^"|"$/, "", v)
      gsub(/[[:space:]]+$/, "", v)
    }
    END { print v }
  '
}

# The marker is configuration for the pipeline, not a release note, so it is
# stripped here and can never reach CHANGELOG.md by either route.
strip_marker() {
  { grep -vE '^feature-build:[[:space:]]*' || true; }
}

blank() { [ -z "$(tr -d '[:space:]' <<<"${1}")" ]; }

# --- which pull request, if any ---------------------------------------------
#
# "The effective entry for this ref" implies "the pull request for this ref, if
# there is one", so the lookup belongs here rather than bolted onto each caller.

if [ -z "${pr}" ]; then
  readonly branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
  mapfile -t open < <(gh pr list --head "${branch}" --state open --json number --jq '.[].number')

  if [ "${#open[@]}" -gt 1 ]; then
    fail "branch ${branch} has ${#open[@]} open pull requests (${open[*]}); which manifest applies is ambiguous"
  fi
  if [ "${#open[@]}" -eq 1 ]; then
    pr="${open[0]}"
    echo "::notice::resolved ${branch} to pull request #${pr}"
  fi
fi
readonly pr

# --- route 1: a file under the changelog directory ---------------------------
#
# With a pull request the manifest is what the pull request *adds*; without one
# it is what the branch *carries*, because there is no diff to consult.

if [ -n "${pr}" ]; then
  mapfile -t files < <(
    gh pr diff "${pr}" --name-only |
      { grep -E "^${changelog_dir}/.+\.md$" || true; } |
      { grep -v "^${changelog_dir}/README\.md$" || true; }
  )
  # One pull request, one entry. A property of the pull request, which is why it
  # is asserted here and not against the directory.
  if [ "${#files[@]}" -gt 1 ]; then
    fail "a pull request carries at most one ${changelog_dir}/ file, found ${#files[@]}: ${files[*]}"
  fi
else
  mapfile -t files < <(
    find "${changelog_dir}" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | sort
  )
  # Deliberately uncounted. A queue batch stages several branches' files side by
  # side and every one of them is legitimate. Ambiguity is more than one
  # *marker*, which is checked below.
fi

file_entry=''
file_marker=''
marked=()
for f in "${files[@]}"; do
  [ -r "${f}" ] || continue
  [ "$(head -n1 "${f}")" == "---" ] || continue
  frontmatter="$(sed -n '2,/^---$/p' "${f}")"
  found="$(marker_value <<<"${frontmatter}")"
  if [ -n "${found}" ]; then
    marked+=("${f}")
    file_marker="${found}"
  fi
done

if [ "${#marked[@]}" -gt 1 ]; then
  fail "more than one ${changelog_dir}/ file carries a feature-build marker: ${marked[*]}"
fi

if [ "${#files[@]}" -eq 1 ] && [ -r "${files[0]}" ]; then
  if [ "$(head -n1 "${files[0]}")" == "---" ]; then
    file_entry="$(sed '1,/^---$/d' "${files[0]}" | sed '1{/^$/d;}')"
  else
    file_entry="$(cat "${files[0]}")"
  fi
elif [ "${#files[@]}" -gt 1 ] && [ "${require_entry}" == "true" ]; then
  fail "${changelog_dir}/ holds ${#files[@]} files and no pull request selects one: ${files[*]}"
fi

# --- route 2: the pull-request body, superseded by a later owner comment ------

pr_section=''
if [ -n "${pr}" ]; then
  meta="$(gh pr view "${pr}" --json body,author,assignees)"
  body_section="$(jq -r '.body // ""' <<<"${meta}" | extract_section)"

  # Anyone may comment on a pull request; only those accountable for the change
  # may rewrite its release note.
  owners="$(jq -c '[.author.login] + [.assignees[].login]' <<<"${meta}")"

  comment_section=''
  while IFS= read -r encoded; do
    candidate="$(base64 --decode <<<"${encoded}" | extract_section)"
    if ! blank "${candidate}"; then
      comment_section="${candidate}"
      break
    fi
  done < <(
    gh pr view "${pr}" --json comments |
      jq -r --argjson owners "${owners}" '
        [.comments[] | select(.author.login as $a | $owners | index($a))]
        | reverse | .[].body | @base64
      '
  )

  pr_section="${comment_section:-${body_section}}"
fi

readonly pr_marker="$(printf '%s\n' "${pr_section}" | marker_value)"
# Removing the marker line leaves the blank that surrounded it, which would be
# carried verbatim into CHANGELOG.md. Trim leading blanks so the entry starts at
# its first category heading whichever route it came by.
readonly pr_entry="$(printf '%s\n' "${pr_section}" | strip_marker | sed '/./,$!d')"

# --- exactly one route -------------------------------------------------------

if ! blank "${file_entry}" && ! blank "${pr_entry}"; then
  fail "both a ${changelog_dir}/ file and a ## CHANGELOG section are present; use one route, not both"
fi

# One manifest, so one marker. The route check compares *entries*, and a file
# holding frontmatter but no entry would slip past it.
if [ -n "${file_marker}" ] && [ -n "${pr_marker}" ]; then
  fail "a feature-build marker is present in both ${files[0]} and the ## CHANGELOG section; use one route, not both"
fi

# --- report -------------------------------------------------------------------

if ! blank "${file_entry}"; then
  route=file
  entry="${file_entry}"
  echo "::notice::changelog entry read from ${files[0]}"
elif ! blank "${pr_entry}"; then
  route=body
  entry="${pr_entry}"
  echo "::notice::changelog entry read from pull request #${pr}"
else
  route=none
  entry=''
  if [ "${require_entry}" == "true" ]; then
    fail "no changelog entry found: add a ## CHANGELOG section to the pull-request body, or a file under ${changelog_dir}/"
  fi
fi

readonly marker="${file_marker:-${pr_marker}}"
if [ -n "${marker}" ]; then
  echo "::notice::feature build marked as ${marker}"
fi

# The entry is multi-line and author-written, so it needs a delimiter that
# cannot occur in it. Asserted rather than assumed: a delimiter collision would
# let arbitrary text be injected into the workflow's outputs.
readonly delimiter="__SYNTHESIZE_CHANGELOG_ENTRY__"
if grep -qF "${delimiter}" <<<"${entry}"; then
  fail "the changelog entry contains ${delimiter}, which is reserved"
fi

{
  echo "route=${route}"
  echo "marker=${marker}"
  echo "pr=${pr}"
  echo "entry<<${delimiter}"
  printf '%s\n' "${entry}"
  echo "${delimiter}"
} >>"${GITHUB_OUTPUT}"
