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
      npm-override-nodejs = import ./tests/buildNpmPackage {
        pkgs = nixpkgs';
        nodejs = nixpkgs'.nodejs-18_x;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
      };
      yarn = import ./tests/buildYarnPackage {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
      };
      yarn-override-nodejs = import ./tests/buildYarnPackage {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
        nodejs = nixpkgs'.nodejs-18_x;
      };
    };
  };
}
