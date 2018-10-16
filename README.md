## Description

nix-npm-buildpackage - build nix packages that use npm/yarn packages

You can use `buildNpmPackage` to:
* convert a `yarn.lock` file to a `packages-lock.json` file if needed
* use a `packages-lock.json` file to:
  - download the dependencies to the nix store
  - build an offline npm cache that uses those
* build a nix package from the npm package

## Examples

```nix
{ pkgs ? import <nixpkgs> {} }:
let
  buildNpmPackage = pkgs.callPackage .../nix-npm-buildpackage {};
  integreties = { # in case the yarn.lock file is missing hashes
   "https://codeload.github.com/foo/bar.js/tar.gz/..." = "sha512-...";
  };
in buildNpmPackage {
  src             = ./.;
  useYarnLock     = true;
  yarnIntegreties = integreties;
}
```

## TODO

* use symlinks to avoid duplication?
* make npm `bin` and `scripts` work?
