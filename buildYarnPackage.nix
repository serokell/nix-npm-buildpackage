{ npmInfo, npmModules, untarAndWrap, depToFetch, commonEnv, lib, runCommand
, fetchurl, writeScriptBin, nodejs, yarn, patchShebangs, writeText, stdenv
, makeWrapper, writeShellScriptBin }:
let

  yarnpkg-lockfile = fetchurl {
    name = "_yarnpkg_lockfile___lockfile_1.1.0.tgz";
    url = "https://registry.yarnpkg.com/@yarnpkg/lockfile/-/lockfile-1.1.0.tgz";
    sha1 = "e77a97fbd345b76d83245edcd17d393b1b41fb31";
  };

  yarnCacheInput = oFile: iFile: overrides:
    let
      self = builtins.listToAttrs (depToFetch iFile);
      final = with lib; fix (foldl' (flip extends) (const self) overrides);
    in writeText oFile (builtins.toJSON final);

  yarnWrapper = writeScriptBin "yarn" ''
    #!${nodejs}/bin/node
    const { promisify } = require('util')
    const child_process = require('child_process');
    const exec = promisify(child_process.exec)
    const { existsSync } = require('fs')
    async function getYarn() {
        const yarn = "${yarn}/bin/yarn"
        if (existsSync(`''${yarn}.js`)) return `''${yarn}.js`
        return yarn
    }
    global.experimentalYarnHooks = {
        async linkStep(cb) {
            const res = await cb()
            console.log("patching shebangs")
            await exec("${patchShebangs}/bin/patchShebangs.sh $SOURCE_DIR/node_modules")
            if (process.env.yarnPostLink) {
              console.log("Running post-link hook")
              console.log(await exec(process.env.yarnPostLink))
            }
            return res
        }
    }
    getYarn().then(require)
  '';

  yarnCmd = "${yarnWrapper}/bin/yarn";
in args@{ src, yarnBuild ? "yarn", yarnBuildMore ? "", integreties ? { }
        , packageOverrides ? [ ], buildInputs ? [ ], yarnFlags ? [ ],
          subdir ? null
, ... }:
let
  deps = { dependencies = builtins.fromJSON (builtins.readFile yarnJson); };
  yarnIntFile = writeText "integreties.json" (builtins.toJSON integreties);
  yarnJson = runCommand "yarn.json" { } ''
    set -e
    mkdir -p node_modules/@yarnpkg/lockfile
    tar -C $_ --strip-components=1 -xf ${yarnpkg-lockfile}
    addToSearchPath NODE_PATH $PWD/node_modules         # @yarnpkg/lockfile
    addToSearchPath NODE_PATH ${npmModules}             # ssri
    ${nodejs}/bin/node ${./mkyarnjson.js} ${src + "/yarn.lock"} ${yarnIntFile} > $out
  '';
  pkgDir = if subdir != null then src + "/" + subdir else src;
in stdenv.mkDerivation (rec {
  inherit (npmInfo pkgDir) pname version;

  preBuildPhases = [ "yarnConfigPhase" "yarnCachePhase" ];
  preInstallPhases = [ "yarnPackPhase" ];

  # TODO
  yarnConfigPhase = ''
    cat <<-END >> .yarnrc
    	yarn-offline-mirror "$PWD/yarn-cache"
    	nodedir "${nodejs}"
    END
  '';

  yarnCachePhase = ''
    mkdir -p yarn-cache
    node ${./mkyarncache.js} ${yarnCacheInput "yarn-cache-input.json" deps packageOverrides}
  '';

  buildPhase = ''
    runHook preBuild

    patchShebangs .
    yarn() { command yarn $yarnFlags "$@"; }
    export SOURCE_DIR="$PWD"
    ${if subdir != null then "cd ${subdir}" else ""}
    ${yarnBuild}
    ${yarnBuildMore}
    runHook postBuild
  '';

  # TODO: install --production?
  yarnPackPhase = ''
    yarn pack --ignore-scripts --filename "${pname}-${version}.tgz"
  '';

  installPhase = ''
    runHook preInstall
    ${untarAndWrap "${pname}-${version}" [ "${yarn}/bin/yarn" ]}
    runHook postInstall
  '';
} // commonEnv // removeAttrs args [ "integreties" "packageOverrides" ] // {
  buildInputs = [ nodejs makeWrapper yarnWrapper ] ++ buildInputs;
  yarnFlags = [ "--offline" "--frozen-lockfile" "--non-interactive" ] ++ yarnFlags;
})
