{
  description = "Build npm and yarn packages";

  outputs = { self, nixpkgs }: {
    legacyPackages.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.callPackage ./default.nix {};
    overlays.default = final: prev: {
      inherit (final.callPackage ./. { }) mkNodeModules buildNpmPackage buildYarnPackage;
    };
    checks.x86_64-linux = let
      nixpkgs' = nixpkgs.legacyPackages.x86_64-linux;
    in {
      npm6 = import ./tests/buildNpmPackage {
        pkgs = nixpkgs';
        npm-buildpackage = self.legacyPackages.x86_64-linux.override {
          nodejs = nixpkgs'.nodejs-14_x;
        };
      };
      npm8 = import ./tests/buildNpmPackage {
        pkgs = nixpkgs';
        npm-buildpackage = self.legacyPackages.x86_64-linux.override {
          nodejs = nixpkgs'.nodejs-18_x;
        };
      };
      yarn = import ./tests/buildNpmPackage/yarn.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
      };
    };
  };
}
