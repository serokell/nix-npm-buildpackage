{ pkgs, npm-buildpackage }:

npm-buildpackage.buildYarnPackage {
  src = pkgs.lib.cleanSourceWith {
    name = "simple-test-source";
    src = ./.;
    filter = path: type: baseNameOf path != "node_modules" && baseNameOf path != "out";
  };
  yarnBuildMore = "yarn run build";
}
