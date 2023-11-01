# Standalone script for creating multi-arch builders

* This is a modified version of the shell script in the action, but essentially does the same thing.
* It assumes the build and run images in the builder toml file are multi-arch and provide `amd64` and `arm64` architecture linux images.
* This version of the script does not inject the lifecycle url into the builder toml.



The `imgutil-pr-232-verify-*.sh`` scripts and corresponding `.log` files show how the standalone script was used to identify the issue fixed in the following PR.

https://github.com/buildpacks/imgutil/pull/232
