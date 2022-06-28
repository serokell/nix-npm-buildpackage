{ pkgs, npm-buildpackage, nodejs ? pkgs.nodejs }:

npm-buildpackage.buildNpmPackage {
  inherit nodejs;
  src = pkgs.lib.cleanSourceWith {
    name = "simple-test-source";
    src = ./.;
    filter = path: type: baseNameOf path != "node_modules" && baseNameOf path != "out";
  };
  npmBuild = "npm run build";
}
