let
  # we pin nixpkgs revision for tests
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};

  npm-buildpackage = pkgs.callPackage ./default.nix {};
in
{
  buildNpmPackage = import ./tests/buildNpmPackage { inherit pkgs npm-buildpackage; };
  localDeps = import ./tests/localDeps { inherit pkgs npm-buildpackage; };
}
