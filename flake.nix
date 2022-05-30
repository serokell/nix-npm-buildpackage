{
  description = "Build npm and yarn packages";

  outputs = { self, nixpkgs }: {
    legacyPackages.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.callPackage ./default.nix {};
    overlays.default = final: prev: {
      inherit (final.callPackage ./. { }) mkNodeModules buildNpmPackage buildYarnPackage;
    };
    checks.x86_64-linux = {
      npm = import ./tests/buildNpmPackage {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
      };
      yarn = import ./tests/buildNpmPackage/yarn.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        npm-buildpackage = self.legacyPackages.x86_64-linux;
      };
    };
  };
}
