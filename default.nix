{ writeShellScriptBin, writeText, runCommand, writeScriptBin, stdenv, lib
, fetchurl, makeWrapper, nodejs, yarn, jq }:
with lib;
let
  inherit (builtins) fromJSON toJSON split removeAttrs toFile;

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  depFetchOwn = { resolved, integrity, name ? null, ... }:
    let
      ssri = split "-" integrity;
      hashType = head ssri;
      hash = elemAt ssri 2;
      bname = baseNameOf resolved;
      fname = if hasSuffix ".tgz" bname || hasSuffix ".tar.gz" bname then
        bname
      else
        bname + ".tgz";
    in nameValuePair resolved {
      inherit name bname;
      path = fetchurl {
        name = fname;
        url = resolved;
        "${hashType}" = hash;
      };
    };

  overrideTgz = src:
    runCommand "${src.name}.tgz" { } ''
      cp -r --reflink=auto ${src} ./package
      chmod +w ./package ./package/package.json
      # scripts are not supported
      ${jq}/bin/jq '.scripts={}' ${src}/package.json > ./package/package.json
      tar --sort=name --owner=0:0 --group=0:0 --mtime='UTC 2019-01-01' -czf $out package
    '';

  overrideToFetch = pkg: { path = "${overrideTgz pkg}"; };

  depToFetch = args@{ resolved ? null, dependencies ? { }, ... }:
    (optional (resolved != null) (depFetchOwn args))
    ++ (depsToFetches dependencies);

  # TODO: Make the override semantics similar to yarnCacheInput and
  #       deduplicate.
  cacheInput = oFile: iFile: overrides:
    writeText oFile (toJSON ((listToAttrs (depToFetch iFile))
      // (builtins.mapAttrs (_: overrideToFetch) overrides)));

  patchShebangs = writeShellScriptBin "patchShebangs.sh" ''
    set -e
    source ${stdenv}/setup
    patchShebangs "$@"
  '';

  npmInfo = src: rec {
    info = fromJSON (readFile (src + "/package.json"));
    pname = info.name or "unknown-node-package";
    version = info.version or "unknown";
  };

  npmModules = "${nodejs}/lib/node_modules/npm/node_modules";

  shellWrap = writeShellScriptBin "npm-shell-wrap.sh" ''
    set -e
    pushd ''${PWD%%node_modules*}/node_modules
      ${patchShebangs}/bin/patchShebangs.sh .
    popd
    exec bash "$@"
  '';

  npmFlagsNpm = [
    "--cache=${
    # `npm ci` had been treating `cache` parameter incorrently since npm 6.11.3, it was fixed in 6.13.5
    # https://github.com/npm/cli/pull/550
      if versionAtLeast nodejs.version "10.17.0"
      && !(versionAtLeast nodejs.version "10.20.0") then
        "./npm-cache/_cacache"
      else
        "./npm-cache"
    }"
    "--nodedir=${nodejs}"
    "--no-update-notifier"
    "--offline"
    "--script-shell=${shellWrap}/bin/npm-shell-wrap.sh"
  ];

  commonEnv = {
    XDG_CONFIG_DIRS = ".";
    NO_UPDATE_NOTIFIER = true;
    installJavascript = true;
  };

  commonBuildInputs = [ nodejs makeWrapper ]; # TODO: git?

  # unpack the .tgz into output directory and add npm wrapper
  # TODO: "cd $out" vs NIX_NPM_BUILDPACKAGE_OUT=$out?
  untarAndWrap = name: cmds: ''
    shopt -s nullglob
    mkdir -p $out/bin
    tar xzvf ./${name}.tgz -C $out --strip-components=1
    if [ "$installJavascript" = "1" ]; then
      cp -R node_modules $out/
      patchShebangs $out/bin
      for i in $out/bin/*.js; do
        makeWrapper ${nodejs}/bin/node $out/bin/$(basename $i .js) \
          --add-flags $i --run "cd $out"
      done
      ${
        concatStringsSep ";" (map (cmd:
          ''
            makeWrapper ${cmd} $out/bin/${
              baseNameOf cmd
            } --run "cd $out" --prefix PATH : ${stdenv.shellPackage}/bin'')
          cmds)
      }
    fi
  '';

in rec {
  mkNodeModules = { src, packageOverrides, extraEnvVars ? { }, pname, version, buildInputs ? [] }:
    let
      packageJson = src + /package.json;
      packageLockJson = src + /package-lock.json;
      info = fromJSON (readFile packageJson);
      lock = fromJSON (readFile packageLockJson);
    in stdenv.mkDerivation ({
      name = "${pname}-${version}-node-modules";

      buildInputs = [ nodejs jq ] ++ buildInputs;

      npmFlags = npmFlagsNpm;
      buildCommand = ''
        # Inside nix-build sandbox $HOME points to a non-existing
        # directory, but npm may try to create this directory (e.g.
        # when you run `npm install` or `npm prune`) and will succeed
        # if you have a single-user nix installation (because / is
        # writable in this case), causing different behavior for
        # single-user and multi-user nix. Set $HOME to a read-only
        # directory to fix it
        export HOME=$(mktemp -d)
        chmod a-w "$HOME"

        # do not run the toplevel lifecycle scripts, we only do dependencies
        cp ${toFile "package.json" (builtins.toJSON (info // { scripts = { }; }))} ./package.json
        cp ${toFile "package-lock.json" (builtins.toJSON lock)} ./package-lock.json

        echo 'building npm cache'
        chmod u+w ./package-lock.json

        addToSearchPath NODE_PATH ${npmModules} # ssri
        node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock packageOverrides}

        echo 'building node_modules'
        npm $npmFlags ci
        patchShebangs ./node_modules/

        mkdir $out
        mv ./node_modules $out/
      '';
    } // extraEnvVars);

  buildNpmPackage = args@{ src, npmBuild ? ''
    # this is what npm runs by default, only run when it exists
    ${jq}/bin/jq -e '.scripts.prepublish' package.json >/dev/null && npm run prepublish
    ${jq}/bin/jq -e '.scripts.prepare' package.json >/dev/null && npm run prepare
  '', buildInputs ? [ ], packageOverrides ? { }, extraEnvVars ? { }
    , extraNodeModulesArgs ? {}
    , # environment variables passed through to `npm ci`
    ... }:
    let
      inherit (npmInfo src) pname version;
      nodeModules = mkNodeModules ({
        inherit src packageOverrides extraEnvVars pname version;
      } // extraNodeModulesArgs);
    in stdenv.mkDerivation ({
      inherit pname version;

      configurePhase = ''
        export HOME=$(mktemp -d)
        chmod a-w "$HOME"

        if [[ -e ./node_modules ]]; then
          echo 'WARNING: node_modules directory already exists, removing it'
          rm -rf ./node_modules
        fi

        patchShebangs .

        cp --reflink=auto -r ${nodeModules}/node_modules ./node_modules
        chmod -R u+w ./node_modules
      '';

      buildPhase = ''
        runHook preBuild
        ${npmBuild}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # `npm prune` uses cache for some reason
        npm prune --production --cache=./npm-prune-cache/
        npm pack --ignore-scripts
        ${untarAndWrap "${pname}-${version}" [ "${nodejs}/bin/npm" ]}

        runHook postInstall
      '';
    } // commonEnv // extraEnvVars
      // removeAttrs args [ "extraEnvVars" "packageOverrides" "extraNodeModulesArgs" ] // {
        buildInputs = commonBuildInputs ++ buildInputs;
      });

  buildYarnPackage = import ./buildYarnPackage.nix {
    inherit lib npmInfo runCommand fetchurl npmModules writeScriptBin nodejs
      yarn patchShebangs writeText stdenv untarAndWrap depToFetch commonEnv
      makeWrapper writeShellScriptBin;
  };
}
