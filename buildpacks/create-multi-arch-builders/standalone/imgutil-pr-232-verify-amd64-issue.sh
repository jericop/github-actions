#!/bin/bash

# This script creates attempts to create a multi-arch builder, but it will fail because the of `amd64` default platform issue when running on `arm64`.

set -euo pipefail

export PACK_IMAGE_URI=buildpacksio/pack:latest

# Only builds and pushes to the local registry
./create-multi-arch-builder.sh example-builder.toml
