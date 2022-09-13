{ pkgs, npm-buildpackage }:

npm-buildpackage.buildYarnPackage {
  src = pkgs.lib.cleanSourceWith {
    name = "simple-test-source";
    src = ./.;
    filter = path: type: baseNameOf path != "node_modules" && baseNameOf path != "out";
  };
  yarnBuildMore = "yarn run build";
  integreties = {
    "https://codeload.github.com/ObsidianLabs/Ethlint/tar.gz/b0e5168ad446f80bcd5fb1d38b9f12e5eaead822" = "sha256:1n5lhjhy0raisyddh8m8xh1v9lcvd65hi8axk8xvm07nplx28514";
  };
}
