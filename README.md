## Description

nix-npm-buildpackage - build nix packages that use npm/yarn packages

You can use `buildNpmPackage`/`buildYarnPackage` to:
* use a `packages-lock.json`/`yarn.lock` file to:
  - download the dependencies to the nix store
  - build an offline npm/yarn cache that uses those
* build a nix package from the npm/yarn package

## Examples

```nix
{ pkgs ? import <nixpkgs> {} }:
let
  bp = pkgs.callPackage .../nix-npm-buildpackage {};
in ...
```

```nix
bp.buildNpmPackage { src = ./.; }
```

```nix
bp.buildYarnPackage { src = ./.; }
```
