#!/bin/bash

set -euo pipefail

readonly project_names=(%project_names%)
readonly runners=(%runners%)

updated_specs=()
updated_xcodeprojs=()

for i in "${!runners[@]}"; do
  runner="${runners[i]}"
  name="${project_names[i]}"

  dir="$BUILD_WORKSPACE_DIRECTORY/${runner%/*}"
  spec_dest="$dir/${name}_spec.json"
  xcodeproj_dest="$dir/$name.xcodeproj"

  "$runner"

  updated_specs+=("$spec_dest")
  updated_xcodeprojs+=("$xcodeproj_dest")
done

if ! %validate%; then
  exit 0
fi

cd "$BUILD_WORKSPACE_DIRECTORY"

for i in "${!updated_xcodeprojs[@]}"; do
  spec="${updated_specs[i]}"
  xcodeproj="${updated_xcodeprojs[i]}"

  diff=$(git diff "$spec")
  if [[ -n "$diff" ]]; then
    echo
    echo "Spec doesn't match expected:"
    echo "$diff"
    echo
    echo 'Commit these changes if you wish to accept them.'
    exit 1
  fi

  diff=$(git diff "$xcodeproj")
  if [[ -n "$diff" ]]; then
    echo
    echo ".xcodeproj doesn't match expected:"
    echo "$diff"
    echo
    echo 'Commit these changes if you wish to accept them.'
    exit 1
  fi
done
