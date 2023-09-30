{
  description = "Build npm and yarn packages";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-darwin"];
  in {
    legacyPackages = builtins.listToAttrs (builtins.map (system: {
        name = system;
        value = nixpkgs.legacyPackages.${system}.callPackage ./default.nix {};
      })
      systems);
    overlays.default = final: prev: {
      inherit (final.callPackage ./. {}) mkNodeModules buildNpmPackage buildYarnPackage;
    };
    checks = builtins.listToAttrs (builtins.map (system: {
        name = system;
        value = let
          nixpkgs' = nixpkgs.legacyPackages.${system};
        in {
          npm6 = import ./tests/buildNpmPackage {
            pkgs = nixpkgs';
            npm-buildpackage = self.legacyPackages.${system}.override {
              nodejs = nixpkgs'.nodejs-14_x;
            };
          };
          npm8 = import ./tests/buildNpmPackage {
            pkgs = nixpkgs';
            npm-buildpackage = self.legacyPackages.${system}.override {
              nodejs = nixpkgs'.nodejs-18_x;
            };
          };
          yarn = import ./tests/buildYarnPackage {
            pkgs = nixpkgs.legacyPackages.${system};
            npm-buildpackage = self.legacyPackages.${system};
          };
        };
      })
      systems);
  };
}
