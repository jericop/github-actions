# github-actions
Custom GitHub Actions

# GitHub Actions

`github-actions` is a collection of [GitHub Actions][gha] for different projects.

[gha]: https://docs.github.com/en/free-pro-team@latest/actions

- [GitHub Actions](#github-actions)
  - [Buildpacks](#buildpacks)
    - [Create Multi-arch Builders](#create-multi-arch-builders)

## Buildpacks

### Create Multi-arch Builders
The `buildpacks/create-multi-arch-builders` action parses `builder-<tag>.toml` files in the given `path` and for each file it creates a multi-arch (amd64, arm64) builder image and publishes them to the given `base-image-uri` with `<tag>` as the tag.

```yaml
uses: jericop/github-actions/buildpacks/create-multi-arch-builders@v1.0.0
with:
  path: 'my-custom-builder'
  base-image-uri: 'ttl.sh/my-custom-builder'
```

#### Inputs <!-- omit in toc -->
| Parameter | Description
| :-------- | :----------
| `path` | The path containing the `builder-<tag>.toml` file(s).
| `base-image-uri` | The base registry uri, without tag, where the multi-arch builder image(s) will be pushed.
| `pack-version` | Optional version of [`pack`](https://github.com/buildpacks/pack) to install. Defaults to `v0.30.0-pre1`.
| `lifecycle-version` | Optional version of [`lifecycle`](https://github.com/buildpacks/lifecycle) to install. Defaults to `v0.17.0-pre.1`.
| `push` | Optional boolean string to push the multi-arch image(s) to `base-image-uri`. Defaults to `true`.

#### Outputs <!-- omit in toc -->
| Parameter | Description
| :-------- | :----------
| `tags` | Space separated builder tags derived from `builder-<tag>.toml` in given `path`
| `local-image-uri` | The local registry uri where multi-arch images are saved before being pushed to `base-image-uri`

