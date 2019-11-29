let
  # we pin nixpkgs revision for tests
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};

  npm-buildpackage = pkgs.callPackage ./default.nix {};
in
  import ./tests/buildNpmPackage { inherit pkgs npm-buildpackage; }
