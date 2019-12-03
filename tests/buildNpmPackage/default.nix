{ pkgs, npm-buildpackage }:

npm-buildpackage.buildNpmPackage {
  packageJson = ./package.json;
  packageLockJson = ./package-lock.json;
  src = builtins.filterSource (path: type: baseNameOf path != "node_modules" && baseNameOf path != "out") ./.;
  npmBuild = "npm run build";
}
