#!/bin/bash

set -euo pipefail

cd "$SRCROOT"

# Calculate Bazel `--output_groups`

readonly swift_outputs_regex='.*\.swiftdoc$|.*\.swiftmodule$|.*\.swiftsourceinfo$'

if [ "$ACTION" == "indexbuild" ]; then
  if [[ "$RULES_XCODEPROJ_BUILD_MODE" == "xcode" ]]; then
    # Inputs for compiling
    readonly output_groups=("all_xc")
  else
    echo "error: \`BazelDependencies\` should not run during Index Build." \
"Please file a bug report here:" \
"https://github.com/buildbuddy-io/rules_xcodeproj/issues/new?template=bug.md" \
        >&2
    exit 1
  fi

  # We don't need to download the indexstore data during Index Build
  readonly remote_download_regex="$swift_outputs_regex"
else
  if [[ "$RULES_XCODEPROJ_BUILD_MODE" == "xcode" ]]; then
    # Inputs for compiling, inputs for linking, and index store data
    readonly output_group_prefixes="xc,xl,xi"
  else
    # Compiled outputs (i.e. swiftmodules), products (i.e. bundles), generated
    # inputs, and index store data
    readonly output_group_prefixes="bc,bp,bg,bi"
  fi

  readonly indexstores_regex='.*\.indexstore/.*'
  readonly remote_download_regex="$indexstores_regex|$swift_outputs_regex"

  # In Xcode 14 the "Index" directory was renamed to "Index.noindex".
  # `$INDEX_DATA_STORE_DIR` is set to `$OBJROOT/INDEX_DIR/DataStore`, so we can
  # use it to determine the name of the directory regardless of Xcode version.
  readonly index_dir="${INDEX_DATA_STORE_DIR%/*}"
  readonly index_dir_name="${index_dir##*/}"

  # Xcode doesn't adjust `$OBJROOT` in scheme action scripts when building for
  # previews. So we need to look in the non-preview build directory for this file.
  readonly non_preview_objroot="${OBJROOT/\/Intermediates.noindex\/Previews\/*//Intermediates.noindex}"
  readonly base_objroot="${non_preview_objroot/\/$index_dir_name\/Build\/Intermediates.noindex//Build/Intermediates.noindex}"
  readonly scheme_target_ids_file="$non_preview_objroot/scheme_target_ids"

  # We need to read from `$output_groups_file` as soon as possible, as concurrent
  # writes to it can happen during indexing, which breaks the off-by-one-by-design
  # nature of it
  IFS=$'\n' read -r -d '' -a labels_and_output_groups < \
    <( "$CALCULATE_OUTPUT_GROUPS_SCRIPT" \
        "$ACTION" \
        "$non_preview_objroot" \
        "$base_objroot" \
        "$scheme_target_ids_file" \
        $output_group_prefixes \
        && printf '\0' )

  raw_labels=()
  output_groups=()
  for (( i=0; i<${#labels_and_output_groups[@]}; i+=2 )); do
    raw_labels+=("${labels_and_output_groups[i]}")
    output_groups+=("${labels_and_output_groups[i+1]}")
  done

  if [ -z "${output_groups:-}" ]; then
    echo "error: BazelDependencies invoked without any output groups set." \
"Please file a bug report here:" \
"https://github.com/buildbuddy-io/rules_xcodeproj/issues/new?template=bug.md" \
      >&2
    exit 1
  else
    labels=()
    while IFS= read -r -d '' label; do
      labels+=("$label")
    done < <(printf "%s\0" "${raw_labels[@]}" | sort -uz)
  fi
fi

# Build

build_pre_config_flags=(
  "--experimental_remote_download_regex=$remote_download_regex"
)

apply_sanitizers=1
if [ "$ACTION" == "indexbuild" ]; then
  readonly config="${BAZEL_CONFIG}_indexbuild"

  # Index Build doesn't need sanitizers
  apply_sanitizers=0
elif [ "${ENABLE_PREVIEWS:-}" == "YES" ]; then
  readonly config="${BAZEL_CONFIG}_swiftuipreviews"
else
  readonly config="_${BAZEL_CONFIG}_build"
fi

# Runtime Sanitizers
if [[ $apply_sanitizers -eq 1 ]]; then
  if [ "${ENABLE_ADDRESS_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(--features=asan)
  fi
  if [ "${ENABLE_THREAD_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(--features=tsan)
  fi
  if [ "${ENABLE_UNDEFINED_BEHAVIOR_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(--features=ubsan)
  fi
fi
readonly build_pre_config_flags

# `bazel_build.sh` sets `indexstores_filelists`
source "$BAZEL_INTEGRATION_DIR/bazel_build.sh"

# Create `bazel.lldbinit``

if [[ "$ACTION" != "indexbuild" && "${ENABLE_PREVIEWS:-}" != "YES" ]]; then
  # shellcheck disable=SC2046
  "$BAZEL_INTEGRATION_DIR/create_lldbinit.sh" \
    "$PROJECT_DIR" \
    $(xargs -n1 <<< "${RESOLVED_EXTERNAL_REPOSITORIES:-}") \
    > "$BAZEL_LLDB_INIT"
fi

# Async actions
#
# For these commands to run in the background, both stdout and stderr need to be
# redirected, otherwise Xcode will block the run script.

readonly log_dir="$OBJROOT/rules_xcodeproj_logs"
mkdir -p "$log_dir"

# Report errors from previous async actions
shopt -s nullglob
for log in "$log_dir"/*.async.log; do
  if [[ -s "$log" ]]; then
    command=$(basename "${log%.async.log}")
    echo "warning: Previous run of \"$command\" had output:" >&2
    sed "s|^|warning: |" "$log" >&2
    echo "warning: If you believe this is a bug, please file a report here:" \
"https://github.com/buildbuddy-io/rules_xcodeproj/issues/new?template=bug.md" \
      >&2
  fi
done

# Import indexes
if [ -n "${indexstores_filelists:-}" ]; then
  "$BAZEL_INTEGRATION_DIR/import_indexstores.sh" \
    "$PROJECT_DIR" \
    "${indexstores_filelists[@]}" \
    >"$log_dir/import_indexstores.async.log" 2>&1 &
fi
