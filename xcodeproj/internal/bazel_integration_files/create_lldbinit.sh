#!/bin/bash

set -euo pipefail

readonly execution_root="$1"
shift

readonly output_base="${execution_root%/*/*}"
readonly build_bazel_out="$execution_root/bazel-out"
readonly build_external="$execution_root/external"

readonly workspace_name="${execution_root##*/}"
readonly index_execution_root="${output_base%/*}/indexbuild_output_base/execroot/$workspace_name"

readonly index_bazel_out="$index_execution_root/bazel-out"
readonly index_external="$index_execution_root/external"

# Load ~/.lldbinit if it exists
if [[ -f "$HOME/.lldbinit" ]]; then
  echo "command source ~/.lldbinit"
fi

# Set `CWD` to `$execution_root` so relative paths in binaries work
#
# This is needed because we use the `oso_prefix_is_pwd` feature, which makes the
# paths to archives relative to the exec root.
echo "platform settings -w \"$execution_root\""

mkdir -p "$index_bazel_out"
mkdir -p "$index_external"

# "Undo" `-debug-prefix-map` for breakpoints
#
# This needs to cause the files to match exactly what Xcode set for breakpoints,
# which is why we don't use `$execution_root` here. Xcode will set the path
# based on the way you opened a file. If you open a file via the Project
# navigator, or indexing (e.g. Jump to Definition), it will use the paths
# specified below.

# `bazel-out` when set from Project navigator
echo "settings set target.source-map ./bazel-out/ \"$BAZEL_OUT\""
# `bazel-out` when set from indexing opened file
echo "settings append target.source-map ./bazel-out/ \"$index_bazel_out\""
# `bazel-out` when set from swiftsourcefile
echo "settings append target.source-map ./bazel-out/ \"$build_bazel_out\""

# `external` for local repositories when set from Project navigator
while [[ $# -gt 0 ]]; do
  dir_name="$1"
  path="$2"
  shift 2
  echo "settings append target.source-map \"./external/$dir_name\" \"$path\""
done

# `external` when set from Project navigator
echo "settings append target.source-map ./external/ \"$BAZEL_EXTERNAL\""
# `external` when set from indexing opened file
echo "settings append target.source-map ./external/ \"$index_external\""
# `external` when set from swiftsourcefile
echo "settings append target.source-map ./external/ \"$build_external\""

# Project files
echo "settings append target.source-map ./ \"$SRCROOT\""

# Import swift_debug_settings.py
#
# This Python module sets a stop hook, that when hit, sets the Swift debug
# settings (i.e. `target.swift-*``) for the module of the current frame. This
# fixes debugging when using `-serialize-debugging-options`.
echo "command script import \"$OBJROOT/swift_debug_settings.py\""
