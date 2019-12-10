{ pkgs, npm-buildpackage }:

npm-buildpackage.buildNpmPackage {
  src = pkgs.lib.cleanSourceWith {
    name = "simple-test-source";
    src = ./.;
    filter = path: type: baseNameOf path != "node_modules" && baseNameOf path != "out";
  };
  npmBuild = "npm run build";
}
