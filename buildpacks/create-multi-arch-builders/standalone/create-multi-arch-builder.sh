#!/bin/bash

# This script creates a multi-arch builder for the builder TOML passed as first arg
# and push it to the destination repo and tag passed as second arg (if supplied)

# export PACK_REPO_URI=https://github.com/jericop/buildpacks-pack.git
# export PACK_REPO_BRANCH=test-imgutil-new-local-image-default-arch
# Note that when PACK_REPO_URI and PACK_REPO_BRANCH are set TMPDIR environment variable is required (if not already set).

## or

# This is useful if you already built a custom pack image (using the repo and branch above) and you want to reuse without rebuliding it.
# export PACK_IMAGE_URI=localhost:5000/pack:latest

# Usage: ./multi-arch.sh <builder-TOML-filename> builderDestRepo:builderDestTag
# Example: ./multi-arch.sh builder.toml ghcr.io/jericop/my-multi-arch-builder:0.0.1

# e: abort script right as an error occurs so it's not overlooked
# u: fail when var refs are undefined, used for required args
# o: used in conjunction with pipefail arg to fail if nonzero in a pipe
set -euo pipefail

# Builder TOML filename, required
# This should be in the root of the docker context because it is copied when creating the architecture-specific builders
builder_toml_file=$1

echo "Creating multi-arch builder from TOML file '$builder_toml_file'..."

# Full URI (registry:optionalPort/repo:tag) to push to. Optional, will skip push when blank
# Parameter expansion (${2:-}) required to avoid fail on empty second arg
dest_image_uri=${2:-}

# Hostname to push to, everything before first slash
dest_registry_hostname=$(cut -d/ -f1 <<< $dest_image_uri)

# Destination image repo:tag (without registry + port)
dest_image=$(cut -d/ -f2- <<< $dest_image_uri)

# Destination tag (dest_image without repo)
dest_image_tag=$(cut -d: -f2 <<< $dest_image)

# This is the dest_image_uri WITHOUT the tag
dest_image_repo="${dest_registry_hostname}/$(cut -d: -f1 <<< $dest_image)"

# Make the tag we use default to latest
tag=${dest_image_tag:-latest}

epoch_timestamp=$(date +'%s')
local_registry_port=5000
local_registry_hostname="localhost:$local_registry_port"
local_registry_pack="$local_registry_hostname/pack-$epoch_timestamp"

if [[ -z "$dest_image_uri" ]]; then
    local_image_uri="$local_registry_hostname/tmp-multi-arch-builder-$epoch_timestamp"
else
    local_image_uri=$(sed "s/$dest_registry_hostname/$local_registry_hostname/" <<< $dest_image_repo-$epoch_timestamp)
fi

local_image_tag="${local_image_uri}:${tag}"

buildx_builder=host-network

# Pull from latest published pack image by default
pack_image_uri="buildpacksio/pack:latest"

setup_registry_buildx() {
    # Create buildx builder with access to host network (if not already created)
    docker buildx use $buildx_builder || docker buildx create --name $buildx_builder --driver-opt network=host --use

    # Start local registry (if not already running)
    docker container inspect registry > /dev/null 2>&1 || docker run -d -p $local_registry_port:5000 --restart=always --name registry registry:2
}

cleanup_registry_buildx() {
    docker buildx stop $buildx_builder
    docker buildx rm $buildx_builder

    docker kill registry
    docker container rm registry
}

# Main script starts from here

setup_registry_buildx

# Or build from source if pack_repo_uri and pack_repo_branch are not empty
if [[ ! -z "${PACK_REPO_URI:-}" && ! -z "${PACK_REPO_BRANCH:-}" ]]; then
    original_dir=$(pwd)
    workspace=$TMPDIR/create-multi-arch-builders/pack

     if [ ! -d $workspace ]; then 
        mkdir -p $workspace
        git clone $PACK_REPO_URI $workspace
        cd $workspace
        git checkout main
        git pull
        git checkout --track origin/$PACK_REPO_BRANCH
     fi

    if [[ $(pwd) != "$workspace" ]]; then 
        cd $workspace
        git pull
    fi

    architecture_images=""
    for arch in amd64 arm64; do
        arch_local_registry_pack="${local_registry_pack}-${arch}"
        
        echo "Building pack binary for $arch_local_registry_pack with: GOOS=linux GOARCH=$arch"
        
        make mod-tidy
        GOOS=linux GOARCH=$arch make build
        
        docker buildx build \
            --tag $arch_local_registry_pack \
            --platform linux/$arch \
            --push --file - . << PACK_EOF
FROM ghcr.io/jericop/build-jammy
COPY out/pack /usr/local/bin/pack
ENTRYPOINT ["/usr/local/bin/pack"]
PACK_EOF
        architecture_images="${architecture_images} ${arch_local_registry_pack}"
    done

    cd $original_dir
    # rm -rf $workspace
    
    docker buildx imagetools create -t ${local_registry_pack} ${architecture_images}
    # Remove provenance images from manifest list IN LOCAL REGISTRY
    crane index filter ${local_registry_pack} --platform linux -t ${local_registry_pack}
    crane manifest ${local_registry_pack} | jq

    pack_image_uri="$local_registry_pack"

fi

if [[ ! -z "${PACK_IMAGE_URI:-}" ]]; then
    pack_image_uri="$PACK_IMAGE_URI"
fi


# Write dockerfile for creating architecture-specific builders
# This is needed in order to copy the toml files into the container at build time
cat <<CREATE_ARCH_BUILDERS_DOCKERFILE_EOF > create-arch-builders.Dockerfile
FROM $pack_image_uri as pack

FROM ghcr.io/jericop/build-jammy
COPY --from=pack /usr/local/bin/pack /usr/local/bin/pack

COPY *.toml ./
RUN <<RUN_EOF

arch=amd64
if [ \$(arch) = "aarch64" ]; then
  arch=arm64
fi

set -e
set -x

arch
uname -a
pack version
pack builder create ${local_image_uri}:${tag}-\${arch} --config ${builder_toml_file} --publish

RUN_EOF
CREATE_ARCH_BUILDERS_DOCKERFILE_EOF

set -x

# Create architecture-specific with pack (through buildx) and publish them to the local registry
# The buildx `--push` flag is not used because pack pushes the images with the `--publish` flag
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --tag not-pushing-so-ignored \
    --progress plain \
    --file create-arch-builders.Dockerfile .

rm create-arch-builders.Dockerfile

# The pack `--publish` flag used above will always use the amd64 architecture, even on an arm64 host.
# This rebases the amd64 layers with the arm64 layers so the container will actually run.
if [ "$(crane config ${local_image_tag}-arm64 | jq .architecture -r)" = "amd64" ]; then
    echo "ERROR The arm64 builder is using an amd64 architecture image"
    
    if [[ ! -z "${REBASE_ARM64_BUILDER_IF_NEEDED:-}" ]]; then
        echo "Rebasing the arm64 builder with the amd64 builder as a workaround"

        crane config "${local_image_tag}-arm64" | jq .architecture

        build_image=""
        if cat $builder_toml_file | grep build-image; then
            build_image=$(cat $builder_toml_file | yj -tj | jq '.stack["build-image"]' -r)
        else
            build_image=$(cat $builder_toml_file | yj -tj | jq .build.image -r)
        fi

        crane manifest $build_image | jq '.manifests| map(select(.platform.os=="linux")) | map({(.platform.architecture|tostring): .digest}) | add' > manifest-arch.json
        build_image_amd64="$(echo $build_image | cut -d: -f1)@$(cat manifest-arch.json | jq .amd64 -r)"
        build_image_arm64="$(echo $build_image | cut -d: -f1)@$(cat manifest-arch.json | jq .arm64 -r)"
        cat manifest-arch.json && rm manifest-arch.json

        crane ls "$(echo $build_image | cut -d: -f1)"

        crane rebase "${local_image_tag}-arm64" \
            --platform linux/arm64 \
            --old_base "${build_image_amd64}" \
            --new_base "${build_image_arm64}" \
            --tag "${local_image_tag}-arm64"
        
        crane config "${local_image_tag}-arm64" | jq .architecture
    fi
    
fi

echo "Creating and pushing multi-arch builder in local registry: $local_image_tag"

docker buildx imagetools create -t "${local_image_tag}" "${local_image_tag}-arm64" "${local_image_tag}-amd64"
# Remove provenance images from manifest list IN LOCAL REGISTRY
crane index filter ${local_image_tag} --platform linux -t ${local_image_tag}
crane manifest ${local_image_tag} | jq

echo "Testing the local multi-arch builder to ensure the lifecycle binary works."

# The pack `--publish` flag used above will always use the amd64 architecture, even on an arm64 host.
# This means it downloads the amd64 lifecycle, even on arm64 hosts. This verifies the correct architecture binary was downloaded.
for arch in amd64 arm64; do
    # Verify lifecycle binary works on this platform
    docker pull --platform linux/$arch --quiet  ${local_image_tag}
    docker run --platform linux/$arch --rm --entrypoint arch ${local_image_tag}
    docker run --platform linux/$arch --rm --entrypoint /cnb/lifecycle/lifecycle ${local_image_tag} -version
done

echo "\$dest_image_uri $dest_image_uri"

if [[ ! -z "$dest_image_uri" ]]; then
    echo "Creating and pushing multi-arch builder: $dest_image_uri"

    # Read dockerfile via stdin from herestring that pulls the multi-arch image from
    # the local registry to create the multi-arch image in the desired registry
    docker buildx build \
        --platform linux/arm64,linux/amd64 \
        --tag "${dest_image_uri}" \
        --provenance=false \
        --push --file - . <<< "FROM ${local_image_tag}"

    crane manifest ${dest_image_uri} | jq
fi

# docker kill registry && docker container rm registry