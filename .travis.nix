# TODO: replace w/ more generic test & also test npm packages
{ pkgs ? import <nixpkgs> {} }:
let
  bp = pkgs.callPackage (import ./default.nix) { inherit pkgs; };
  vault-gist = fetchGit {
    url = "https://github.com/obfusk/nix-vault-with-ui.git";
    rev = "664d3d9a1f30626d0277a62c520cf82df0e0a2a1";
    ref = "664d3d9-tag-you-are-it"; # TODO: "v0.1.0"
  };
in vault-gist { inherit pkgs; npm-buildpackage = bp; }
