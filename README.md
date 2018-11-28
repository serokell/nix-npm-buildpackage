## Description

<!--
[![Build Status](https://travis-ci.org/serokell/nix-npm-buildpackage.svg?branch=master)](https://travis-ci.org/serokell/nix-npm-buildpackage)
-->

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

## About Serokell

`nix-npm-buildpackage` is maintained and funded with :heart: by
[Serokell](https://serokell.io/). The names and logo for Serokell are trademark
of Serokell OÜ.

We love open source software! See [our other
projects](https://serokell.io/community?utm_source=github) or [hire
us](https://serokell.io/hire-us?utm_source=github) to design, develop and grow
your idea!
