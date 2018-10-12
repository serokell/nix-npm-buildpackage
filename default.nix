{ stdenvNoCC, writeShellScriptBin, writeText, runCommand,
  stdenv, fetchurl, makeWrapper, nodejs-10_x, yarn2nix }:
with stdenv.lib; let
  inherit (builtins) fromJSON toJSON split removeAttrs;

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  depFetchOwn = { resolved, integrity, ... }:
    let
      ssri      = split "-" integrity; # standard subresource integrity
      hashType  = head ssri;
      hash      = elemAt ssri 2;
    in nameValuePair resolved (fetchurl {
      url           = resolved;
      "${hashType}" = hash;
    });

  depToFetch = args @ { resolved ? null, dependencies ? {}, ... }:
    (optional (resolved != null) (depFetchOwn args)) ++ (depsToFetches dependencies);

  npmCacheInput = lock: writeText "npm-cache-input.json" (toJSON (listToAttrs (depToFetch lock)));

  patchShebangs = writeShellScriptBin "patchShebangs.sh" ''
    set -e
    source ${stdenvNoCC}/setup
    patchShebangs "$@"
  '';

  shellWrap = writeShellScriptBin "npm-shell-wrap.sh" ''
    set -e
    if [ ! -e .shebangs_patched ]; then
      ${patchShebangs}/bin/patchShebangs.sh .
      touch .shebangs_patched
    fi
    exec bash "$@"
  '';
in
  args @ { src, useYarn ? false, yarnIntegreties ? {},
           npmBuild ? "npm ci", npmBuildMore ? "",
           buildInputs ? [], npmFlags ? [], ... }:
    let
      packageJson     = src + "/package.json";
      packageLockJson = src + "/package-lock.json";
      yarnLock        = src + "/yarn.lock";
      yarnIntFile     = writeText "integreties.json" (toJSON yarnIntegreties);
      lockfile        = if useYarn then mkLockFileFromYarn else packageLockJson;
      info            = fromJSON (readFile packageJson);
      lock            = fromJSON (readFile lockfile);
      name            = "${info.name}-${info.version}";
      npm             = "${nodejs-10_x}/bin/npm";
      npmAlias        = ''npm() { ${npm} "$@" $npmFlags; }'';

      mkLockFileFromYarn = runCommand "yarn-package-lock.json" {} ''
        addToSearchPath NODE_PATH ${nodejs-10_x}/lib/node_modules/npm/node_modules
        addToSearchPath NODE_PATH ${yarn2nix.node_modules}
        ${nodejs-10_x}/bin/node ${./mklock.js} $out ${packageJson} ${yarnLock} ${yarnIntFile}
      '';
    in stdenv.mkDerivation ({
      inherit name src;
      inherit (info) version;

      XDG_CONFIG_DIRS     = ".";
      NO_UPDATE_NOTIFIER  = true;
      preBuildPhases      = [ "npmCachePhase" ];
      preInstallPhases    = [ "npmPackPhase" ];
      installJavascript   = true;

      npmCachePhase = ''
        if [ "$useYarn" -eq "1" ]; then
          cp ${lockfile} ${builtins.baseNameOf packageLockJson}
        fi
        addToSearchPath NODE_PATH ${nodejs-10_x}/lib/node_modules/npm/node_modules
        node ${./mkcache.js} ${npmCacheInput lock}
      '';

      buildPhase = ''
        ${npmAlias}
        runHook preBuild
        ${npmBuild}
        ${npmBuildMore}
        runHook postBuild
      '';

      # make a package .tgz (no way around it)
      npmPackPhase = ''
        ${npmAlias}
        npm prune --production
        npm pack --ignore-scripts
      '';

      # unpack the .tgz into output directory and add npm wrapper
      installPhase = ''
        mkdir -p $out/bin
        tar xzvf ./${name}.tgz -C $out --strip-components=1
        if [ "$installJavascript" -eq "1" ]; then
          cp -R node_modules $out/
          makeWrapper ${npm} $out/bin/npm --run "cd $out"
        fi
      '';
    } // removeAttrs args [ "yarnIntegreties" ] // {
      buildInputs = [ nodejs-10_x makeWrapper ] ++ buildInputs;
      npmFlags = [ "--cache=./npm-cache" "--offline" "--script-shell=${shellWrap}/bin/npm-shell-wrap.sh" ] ++ npmFlags;
    })
