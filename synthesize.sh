#!/usr/bin/env bash
#
# Resolves the changelog manifest for one or more refs and reports what each one
# says: the entry text, the feature-build marker it carries, and which route it
# came by.
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
# Resolving *several* pull requests is part of the contract rather than
# something a caller assembles from repeated invocations. Assembly needs one
# answer per merged pull request, and the alternative — checking this repository
# out and calling this script around a loop — reaches past the action's
# interface into its implementation.
#
# Inputs arrive as environment variables: CHANGELOG_DIR, PR, PRS, REQUIRE_ENTRY.

[ "${RUNNER_DEBUG}" == 1 ] && set -xv
set -euo pipefail

readonly changelog_dir="${CHANGELOG_DIR:-.changelog}"
readonly require_entry="${REQUIRE_ENTRY:-true}"

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

# Prints every `feature-build:` value it finds, one per line, so that a manifest
# carrying more than one is visible to the caller rather than resolved by "first
# wins". Ambiguity is more than one marker, and two markers in one manifest is
# just as ambiguous as two manifests each carrying one.
#
# It reads to end rather than quitting on the first match. An early exit closes
# the pipe under the producer, and `set -o pipefail` then kills the script with
# no diagnosis at all.
marker_values() {
  awk '
    match($0, /^feature-build:[[:space:]]*/) {
      v = substr($0, RLENGTH + 1)
      gsub(/^"|"$/, "", v)
      gsub(/[[:space:]]+$/, "", v)
      print v
    }
  '
}

# One value from one manifest, or a stated error. `${2}` names the manifest for
# the diagnosis.
single_marker() {
  local values
  local -a found=()
  # Captured before splitting, for the same reason the `gh` calls are: a process
  # substitution discards the producer's status, so an awk that failed to run at
  # all would read as "this manifest carries no marker".
  if ! values="$(marker_values <<<"${1}")"; then
    fail "could not read the feature-build marker from ${2}"
  fi
  [ -n "${values}" ] && mapfile -t found <<<"${values}"
  if [ "${#found[@]}" -gt 1 ]; then
    fail "${2} carries ${#found[@]} feature-build lines; a manifest carries at most one"
  fi
  printf '%s' "${found[0]:-}"
}

# The marker is configuration for the pipeline, not a release note, so it is
# stripped here and can never reach CHANGELOG.md by either route.
strip_marker() {
  { grep -vE '^feature-build:[[:space:]]*' || true; }
}

blank() { [ -z "$(tr -d '[:space:]' <<<"${1}")" ]; }

# The pull request for a ref, when the caller has not named one.
#
# "The effective entry for this ref" implies "the pull request for this ref, if
# there is one", so the lookup belongs here rather than in each caller.
resolve_pr_number() {
  local branch listed
  local -a open
  branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"

  # Captured before it is split. Inside a process substitution a failing `gh` —
  # expired token, network, wrong repository — yields an empty list that is
  # indistinguishable from "this branch has no pull request", and the body route
  # then disappears without a word.
  if ! listed="$(gh pr list --head "${branch}" --state open --json number --jq '.[].number')"; then
    fail "could not list pull requests for ${branch}; refusing to guess that it has none"
  fi
  open=()
  [ -n "${listed}" ] && mapfile -t open <<<"${listed}"

  if [ "${#open[@]}" -gt 1 ]; then
    fail "branch ${branch} has ${#open[@]} open pull requests (${open[*]}); which manifest applies is ambiguous"
  fi
  if [ "${#open[@]}" -eq 1 ]; then
    echo "::notice::resolved ${branch} to pull request #${open[0]}" >&2
  fi
  printf '%s' "${open[0]:-}"
}

# Resolves one manifest and prints it as a JSON object: pr, entry, marker, route.
resolve_manifest() {
  local pr="${1}"
  local -a files marked
  local file_entry='' file_marker='' pr_section='' pr_marker='' pr_entry=''
  local f frontmatter found diffed meta owners body_section comment_section candidate encoded
  local route entry

  # --- route 1: a file under the changelog directory -------------------------
  #
  # With a pull request the manifest is what the pull request *adds*; without
  # one it is what the branch *carries*, because there is no diff to consult.
  if [ -n "${pr}" ]; then
    # The paginated files listing rather than `gh pr diff --name-only`: the
    # diff media type is refused outright (HTTP 406) once a pull request
    # exceeds 20,000 diff lines, so the pull requests most in need of a
    # correct manifest — a consolidated stack landing as one merge — were
    # exactly the ones this could not read. The files endpoint pages through
    # any size and names the same net-diff paths.
    #
    # Captured with its status checked, same reason as the listing above: a
    # failing `gh` inside a process substitution would read as "this pull
    # request adds no changelog file".
    if ! diffed="$(gh api "repos/{owner}/{repo}/pulls/${pr}/files" --paginate --jq '.[].filename')"; then
      fail "could not read the file list of #${pr}; refusing to guess that it changes none"
    fi
    # Matched as a literal path rather than interpolated into an expression.
    # The default directory is `.changelog`, whose leading dot is a wildcard in
    # a regular expression — so `achangelog/x.md` matched, and any caller whose
    # directory name contained a metacharacter matched something else again.
    mapfile -t files < <(
      printf '%s\n' "${diffed}" |
        while IFS= read -r path; do
          case "${path}" in
            "${changelog_dir}/README.md") continue ;;
            "${changelog_dir}"/*.md) printf '%s\n' "${path}" ;;
          esac
        done
    )
    # One pull request, one entry. A property of the pull request, which is why
    # it is asserted here and not against the directory.
    if [ "${#files[@]}" -gt 1 ]; then
      fail "a pull request carries at most one ${changelog_dir}/ file, found ${#files[@]}: ${files[*]}"
    fi
  else
    mapfile -t files < <(
      find "${changelog_dir}" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | sort
    )
    # Deliberately uncounted. A queue batch stages several branches' files side
    # by side and every one of them is legitimate. Ambiguity is more than one
    # *marker*, which is checked below.
  fi

  marked=()
  for f in "${files[@]}"; do
    [ -r "${f}" ] || continue
    [ "$(head -n1 "${f}")" == "---" ] || continue
    frontmatter="$(sed -n '2,/^---$/p' "${f}")"
    # Checked explicitly. `set -e` does not reliably carry a failure out through
    # two levels of command substitution, and this function is already called
    # from one — which is how "two markers" came back as "none".
    if ! found="$(single_marker "${frontmatter}" "${f}")"; then exit 1; fi
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

  # --- route 2: the body, superseded by a later owner comment ----------------
  if [ -n "${pr}" ]; then
    meta="$(gh pr view "${pr}" --json body,author,assignees)"
    body_section="$(jq -r '.body // ""' <<<"${meta}" | extract_section)"

    # Anyone may comment on a pull request; only those accountable for the
    # change may rewrite its release note.
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

  # Assigned before being read, deliberately. `readonly x="$(cmd)"` is a single
  # builtin invocation whose status is the builtin's, not the command's, so a
  # failure inside the substitution is swallowed and `set -e` never sees it —
  # which turned "this manifest carries two markers" into "it carries none".
  if ! pr_marker="$(single_marker "${pr_section}" "the ## CHANGELOG section of #${pr}")"; then exit 1; fi
  # Removing the marker line leaves the blank that surrounded it, which would be
  # carried verbatim into CHANGELOG.md. Trim leading blanks so the entry starts
  # at its first category heading whichever route it came by.
  pr_entry="$(printf '%s\n' "${pr_section}" | strip_marker | sed '/./,$!d')"

  # --- exactly one route -----------------------------------------------------

  if ! blank "${file_entry}" && ! blank "${pr_entry}"; then
    fail "both a ${changelog_dir}/ file and a ## CHANGELOG section are present; use one route, not both"
  fi

  # One manifest, so one marker. The route check compares *entries*, and a file
  # holding frontmatter but no entry would slip past it.
  if [ -n "${file_marker}" ] && [ -n "${pr_marker}" ]; then
    fail "a feature-build marker is present in both ${marked[0]} and the ## CHANGELOG section; use one route, not both"
  fi

  if ! blank "${file_entry}"; then
    route=file
    entry="${file_entry}"
    echo "::notice::changelog entry read from ${files[0]}" >&2
  elif ! blank "${pr_entry}"; then
    route=body
    entry="${pr_entry}"
    echo "::notice::changelog entry read from pull request #${pr}" >&2
  else
    route=none
    entry=''
    if [ "${require_entry}" == "true" ]; then
      fail "no changelog entry: add a ## CHANGELOG section to the pull-request body, or a ${changelog_dir}/ file"
    fi
  fi

  local marker="${file_marker:-${pr_marker}}"

  # The marker is author-written and ends up in a version string, so its shape
  # is checked here rather than by each consumer.
  #
  # `<user>-<ticket>`: the publishing action's version pattern requires exactly
  # two alphanumeric segments after the version. A marker that does not match it
  # produces no version, and the build then reports an ordinary build with
  # nothing said about the marker the author wrote — a silent degradation this
  # turns into a stated error.
  #
  # Newlines cannot reach here: the marker is read from a single line by awk. It
  # is the space and the slash that matter, which yield a version no registry
  # will accept.
  if [ -n "${marker}" ] && ! [[ "${marker}" =~ ^[A-Za-z0-9]+-[A-Za-z0-9]+$ ]]; then
    # Reported through a sanitised copy: the raw value is exactly what is not
    # trusted, and it is about to be printed.
    local printable
    printable="$(tr -cd '[:alnum:][:punct:] ' <<<"${marker}" | cut -c1-40)"
    fail "\"${printable}\" is not a usable feature-build marker; use <user>-<ticket>, alphanumeric segments"
  fi

  if [ -n "${marker}" ]; then
    echo "::notice::feature build marked as ${marker}" >&2
  fi

  jq -n --arg pr "${pr}" --arg entry "${entry}" --arg marker "${marker}" --arg route "${route}" \
    '{pr: $pr, entry: $entry, marker: $marker, route: $route}'
}

# --- resolve one, or the list the caller named --------------------------------

declare -a wanted=()
if [ -n "${PRS:-}" ]; then
  if [ -n "${PR:-}" ]; then
    fail "pass either pr or prs, not both"
  fi
  # Whitespace-separated so a caller may pass a YAML block, a JSON array's
  # contents, or a single line without having to care which.
  read -r -a wanted <<<"$(tr ',\n' '  ' <<<"${PRS}")"
else
  wanted=("${PR:-$(resolve_pr_number)}")
fi

declare -a resolved=()
for want in "${wanted[@]}"; do
  [ -n "${want}" ] || continue
  if [ -n "${PRS:-}" ]; then
    echo "::notice::resolving #${want}" >&2
  fi
  if ! obj="$(resolve_manifest "${want}")"; then exit 1; fi
  resolved+=("${obj}")
done

# An empty list is not an error: a ref with no pull request and no file has
# nothing to say, and `require_entry` already governs whether that is allowed.
if [ "${#resolved[@]}" -eq 0 ]; then
  if ! obj="$(resolve_manifest "")"; then exit 1; fi
  resolved+=("${obj}")
fi

entries="$(printf '%s\n' "${resolved[@]}" | jq -s -c '.')"

# The entry is multi-line and author-written, so it needs a delimiter that
# cannot occur in it. Asserted rather than assumed: a delimiter collision would
# let arbitrary text be injected into the workflow's outputs.
readonly delimiter="__SYNTHESIZE_CHANGELOG_ENTRY__"

first_entry="$(jq -r '.[0].entry' <<<"${entries}")"
if grep -qF "${delimiter}" <<<"${first_entry}"; then
  fail "the changelog entry contains ${delimiter}, which is reserved"
fi

{
  echo "entries=${entries}"
  # The singular outputs describe the single manifest, and are what the merge
  # gate and the build read. With a list they describe the first, which is why a
  # caller passing `prs` reads `entries` instead.
  echo "route=$(jq -r '.[0].route' <<<"${entries}")"
  echo "marker=$(jq -r '.[0].marker' <<<"${entries}")"
  echo "pr=$(jq -r '.[0].pr' <<<"${entries}")"
  echo "entry<<${delimiter}"
  printf '%s\n' "${first_entry}"
  echo "${delimiter}"
} >>"${GITHUB_OUTPUT}"
