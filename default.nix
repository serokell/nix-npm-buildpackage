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
      fname     = baseNameOf resolved;
    in nameValuePair resolved (fetchurl {
      url           = resolved;
      "${hashType}" = hash;
      name          = if hasSuffix ".tgz" fname || hasSuffix ".tar.gz" fname
                      then fname else fname + ".tgz";
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
  args @ { src, useYarnLock ? false, yarnIntegreties ? {},
           npmBuild ? "npm ci", npmBuildMore ? "",
           buildInputs ? [], npmFlags ? [], ... }:
    let
      pkgJson         = src + "/package.json";
      pkgLockJson     = src + "/package-lock.json";
      yarnLock        = src + "/yarn.lock";

      yarnIntFile     = writeText "integreties.json" (toJSON yarnIntegreties);
      lockfile        = if useYarnLock then mkLockFileFromYarn else pkgLockJson;

      info            = fromJSON (readFile pkgJson);
      lock            = fromJSON (readFile lockfile);

      name            = "${info.name}-${info.version}";
      npm             = "${nodejs-10_x}/bin/npm";
      npmAlias        = ''npm() { ${npm} "$@" $npmFlags; }'';
      npmModules      = "${nodejs-10_x}/lib/node_modules/npm/node_modules";

      mkLockFileFromYarn = runCommand "yarn-package-lock.json" {} ''
        set -e
        addToSearchPath NODE_PATH ${npmModules}
        addToSearchPath NODE_PATH ${yarn2nix.node_modules}
        ${nodejs-10_x}/bin/node ${./mklock.js} $out ${pkgJson} ${yarnLock} ${yarnIntFile}
      '';
    in stdenv.mkDerivation ({
      inherit name;
      inherit (info) version;

      XDG_CONFIG_DIRS     = ".";
      NO_UPDATE_NOTIFIER  = true;
      preBuildPhases      = [ "npmCachePhase" ];
      preInstallPhases    = [ "npmPackPhase" ];
      installJavascript   = true;

      npmCachePhase = ''
        set -e
        if [ "$useYarnLock" = "1" ]; then
          cp ${lockfile} ${builtins.baseNameOf pkgLockJson}
          chmod u+w ${builtins.baseNameOf pkgLockJson}
        fi
        addToSearchPath NODE_PATH ${npmModules}
        node ${./mkcache.js} ${npmCacheInput lock}
      '';

      buildPhase = ''
        set -e
        ${npmAlias}
        runHook preBuild
        ${npmBuild}
        ${npmBuildMore}
        runHook postBuild
      '';

      # make a package .tgz (no way around it)
      npmPackPhase = ''
        set -e
        ${npmAlias}
        npm prune --production
        npm pack --ignore-scripts
      '';

      # unpack the .tgz into output directory and add npm wrapper
      installPhase = ''
        set -e
        mkdir -p $out/bin
        tar xzvf ./${name}.tgz -C $out --strip-components=1
        if [ "$installJavascript" = "1" ]; then
          cp -R node_modules $out/
          makeWrapper ${npm} $out/bin/npm --run "cd $out"
        fi
      '';
    } // removeAttrs args [ "yarnIntegreties" ] // {
      buildInputs = [ nodejs-10_x makeWrapper ] ++ buildInputs;
      npmFlags    = [ "--cache=./npm-cache" "--offline" "--script-shell=${shellWrap}/bin/npm-shell-wrap.sh" ] ++ npmFlags;
    })
