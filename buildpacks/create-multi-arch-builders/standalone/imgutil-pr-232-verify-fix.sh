#!/bin/bash

# This script creates a multi-arch builder by building pack from the given repo and branch.
# It demonstrates that the changes in given pack repo and branch fix the `amd64` default platform issue when running on `arm64`.

set -euo pipefail

export PACK_REPO_URI=https://github.com/jericop/buildpacks-pack.git
export PACK_REPO_BRANCH=imgutil-default-platform-change-test

# Only builds and pushes to the local registry
./create-multi-arch-builder.sh example-builder.toml
