# This script will create multi-arch builders from builder-<tag>.toml files in the current directory, 
# where <tag> will be the tag named used for multi-arch builder image created

set -euo pipefail

# script args

# This is the registry hostname and repo name minus the tag
base_image_uri=${1:-}

# The script expects to find builder-<tag>.toml files in this directory
folder=./

cd $folder

# Injected (or updated) in each builder-<tag>.toml file
lifecycle_version=v0.17.0-rc.3

# Allow override through environment variable
if [ ! -z "${LIFECYCLE_VERSION:-}" ]; then
    lifecycle_version=$LIFECYCLE_VERSION
fi

# Used for installing pack from releases
pack_version=v0.30.0-pre2

# Allow override through environment variable
if [ ! -z "${PACK_VERSION:-}" ]; then
    pack_version=$PACK_VERSION
fi

local_registry_port=5000
local_registry_hostname="localhost:$local_registry_port"
local_registry_pack="$local_registry_hostname/pack"

buildx_builder=host-network

registry_hostname=$(echo $base_image_uri | cut -d/ -f1)
local_image_uri=$(echo $base_image_uri | sed "s/$registry_hostname/$local_registry_hostname/")

# Gets tag from builder.toml that are named: builder-<tag>.toml
tags=$(ls *.toml | xargs -n1 | cut -d- -f2 | cut -d. -f1 | xargs)

if [ -z "$base_image_uri" ]; then
    echo "The first argument must be the base_image_uri where the multi-arch builders will be pushed."
    exit 1
fi

# Build from releases by default
build_pack_from_releases_dockerfile_replace=$(cat <<'PACK_FROM_RELEASES_EOF'
FROM curlimages/curl
USER root
RUN <<RUN_EOF
VERSION="REPLACE_PACK_VERSION"
TAR_FILENAME="pack-${VERSION}-linux.tgz"
RELEASES_BASE_URL="https://github.com/buildpacks/pack/releases/download"

if [ $(arch) = "aarch64" ]; then
TAR_FILENAME="pack-${VERSION}-linux-arm64.tgz"
fi

curl -fsSL -O "${RELEASES_BASE_URL}/${VERSION}/${TAR_FILENAME}"
tar -C /usr/local/bin/ --no-same-owner -xzv -f "$TAR_FILENAME" pack
rm $TAR_FILENAME
RUN_EOF

ENTRYPOINT ["/usr/local/bin/pack"]
PACK_FROM_RELEASES_EOF
)
build_pack_dockerfile=$(echo "$build_pack_from_releases_dockerfile_replace" | sed "s/REPLACE_PACK_VERSION/$pack_version/")

# Or build from source if pack_repo_uri and pack_repo_branch are not empty
if [[ ! -z "${PACK_REPO_URI:-}" && ! -z "${PACK_REPO_BRANCH:-}" ]]; then
# can't indent because of heredoc
build_pack_dockerfile=$(cat <<PACK_FROM_SOURCE_EOF
FROM golang:1.19 as builder
WORKDIR /workspace/pack
RUN git clone $PACK_REPO_URI /workspace/pack && git checkout $PACK_REPO_BRANCH
RUN make mod-tidy build

FROM ubuntu:jammy
RUN apt-get update && apt-get install -y ca-certificates
COPY --from=builder /workspace/pack/out/pack /usr/local/bin/pack
ENTRYPOINT ["/usr/local/bin/pack"]
PACK_FROM_SOURCE_EOF
)
fi

setup_registry_buildx() {
    # Create buildx builder with access to host network (if not already created)
    docker buildx use $buildx_builder || docker buildx create --name $buildx_builder --driver-opt network=host --use

    # Start local registry (if not already running)
    docker container inspect registry > /dev/null 2>&1 || docker run -d -p $local_registry_port:$local_registry_port --restart=always --name registry registry:2
}

cleanup_registry_buildx() {
    docker buildx stop $buildx_builder
    docker buildx rm $buildx_builder

    docker kill registry
    docker container rm registry
}

# Main script starts from there

setup_registry_buildx


# Create custom multi-arch pack image because the `buildpacksio/pack` image does not contain stand-alone binary
docker buildx build \
    -t $local_registry_pack \
    --quiet \
    --platform linux/amd64,linux/arm64 \
    --push - <<PACK_EOF
$build_pack_dockerfile
PACK_EOF

# Write dockerfile for creating architecture-specific builders
# This is needed in order to copy the toml files into the container at build time
cat <<CREATE_ARCH_BUILDERS_DOCKERFILE_EOF > create-arch-builders.Dockerfile
FROM ghcr.io/jericop/go-arch as go-arch
FROM $local_registry_pack as pack

FROM ghcr.io/jericop/build-jammy
USER root
COPY --from=go-arch /usr/local/bin/go-arch /usr/local/bin/go-arch
COPY --from=pack /usr/local/bin/pack /usr/local/bin/pack

COPY *.toml ./
RUN <<RUN_EOF

arch_=amd64
lifecycle_arch=x86-64

if [ \$(arch) = "aarch64" ]; then
  arch_=arm64
  lifecycle_arch=arm64
fi

set -e
set -x

uname -a
go-arch
pack version

for tag in $tags; do
    local_image_tag="${local_image_uri}:\${tag}-\${arch_}"
    builder_toml="builder-\${tag}.toml"

    # This is a workaround because pack downloads the lifecycle binary for x86-64, even on arm64.
    # TODO: fix this
    lifecycle_url="https://github.com/buildpacks/lifecycle/releases/download/${lifecycle_version}/lifecycle-${lifecycle_version}+linux.\${lifecycle_arch}.tgz"
    cat \${builder_toml} | yj -tj | jq ". + {lifecycle: {uri: \"\$lifecycle_url\"}}" | yj -jt > updated.toml
    mv updated.toml \${builder_toml}
    
    # cat \${builder_toml}

    pack builder create \${local_image_tag} --config \${builder_toml} --publish --verbose
done

RUN_EOF
CREATE_ARCH_BUILDERS_DOCKERFILE_EOF

echo "finished writing create-arch-builders.Dockerfile"

set -x

# Create architecture-specific with pack (through buildx) and publish them to the local registry
# The buildx `--push` flag is not used because pack pushes the images with the `--publish` flag
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t not-pushing-so-ignored \
    --progress plain \
    -f create-arch-builders.Dockerfile .

rm create-arch-builders.Dockerfile


echo "finished building create-arch-builders.Dockerfile"

# Finally we can create the multi-arch builders using the architecture-specific builders created above
for tag in $tags; do
    local_image_tag="${local_image_uri}:${tag}"
    image_tag="${base_image_uri}:${tag}"

    # As of pack version 0.30.0-pre1 publishing with `--publish` will always use the linux/amd64 image,
    # even on arm64. This rebases the amd64 layers with the arm64 layers so the container will actually run.
    if [ "$(crane config ${local_image_tag}-arm64 | jq .architecture -r)" = "amd64" ]; then
        crane config "${local_image_tag}-arm64" | jq .architecture
        crane ls "${local_image_uri}"

        build_image=""
        if cat "builder-${tag}.toml" | grep build-image; then
            build_image=$(cat builder-${tag}.toml | yj -tj | jq '.stack["build-image"]' -r)
        else
            build_image=$(cat builder-${tag}.toml | yj -tj | jq .build.image -r)
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

    # Create a multi-arch image in the local registry first
    docker buildx imagetools create -t "${local_image_tag}" "${local_image_tag}-arm64" "${local_image_tag}-amd64"
    docker buildx imagetools inspect "${local_image_tag}"
    
    # Create a dockerfile that pulls the multi-arch image from the local registry
    # in order to create the multi-arch image in the desired registry
    echo "FROM ${local_image_tag}" > multi-arch-builder.Dockerfile
    docker buildx build \
        --platform linux/arm64,linux/amd64 \
        --tag "${image_tag}" --push \
        --file multi-arch-builder.Dockerfile .
    docker buildx imagetools inspect "${image_tag}"
    rm multi-arch-builder.Dockerfile
done

# docker kill registry && docker container rm registry