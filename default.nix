{ stdenvNoCC, writeShellScriptBin, writeText, runCommand, writeScriptBin,
  stdenv, fetchurl, makeWrapper, nodejs-10_x, yarn2nix, yarn }:
with stdenv.lib; let
  inherit (builtins) fromJSON toJSON split removeAttrs;

  _nodejs = nodejs-10_x;
  _yarn   = yarn.override { nodejs = _nodejs; };

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  depFetchOwn = { resolved, integrity, name ? null, ... }:
    let
      ssri      = split "-" integrity;
      hashType  = head ssri;
      hash      = elemAt ssri 2;
      bname     = baseNameOf resolved;
      fname     = if hasSuffix ".tgz" bname || hasSuffix ".tar.gz" bname
                  then bname else bname + ".tgz";
    in nameValuePair resolved {
      inherit name bname;
      path = fetchurl { name = fname; url = resolved; "${hashType}" = hash; };
    };

  depToFetch = args @ { resolved ? null, dependencies ? {}, ... }:
    (optional (resolved != null) (depFetchOwn args)) ++ (depsToFetches dependencies);

  cacheInput = oFile: iFile: writeText oFile (toJSON (listToAttrs (depToFetch iFile)));

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

  npmInfo = src: rec {
    pkgJson = src + "/package.json";
    info    = fromJSON (readFile pkgJson);
    name    = "${info.name}-${info.version}";
  };

  yarnWrapper = writeScriptBin "yarn" ''
    #!${_nodejs}/bin/node
    const { promisify } = require('util')
    const child_process = require('child_process');
    const exec = promisify(child_process.exec)
    const { existsSync } = require('fs')
    async function getYarn() {
        const yarn = "${_yarn}/bin/yarn"
        if (existsSync(`''${yarn}.js`)) return `''${yarn}.js`
        return yarn
    }
    global.experimentalYarnHooks = {
        async linkStep(cb) {
            const res = await cb()
            console.log("patching shebangs")
            await exec("${patchShebangs}/bin/patchShebangs.sh node_modules")
            return res
        }
    }
    getYarn().then(require)
  '';

  npmCmd        = "${_nodejs}/bin/npm";
  npmAlias      = ''npm() { ${npmCmd} "$@" $npmFlags; }'';
  npmModules    = "${_nodejs}/lib/node_modules/npm/node_modules";

  yarnCmd       = "${yarnWrapper}/bin/yarn";
  yarnAlias     = ''yarn() { ${yarnCmd} $yarnFlags "$@"; }'';

  npmFlagsYarn  = [ "--offline" "--script-shell=${shellWrap}/bin/npm-shell-wrap.sh" ];
  npmFlagsNpm   = [ "--cache=./npm-cache" "--nodedir=${_nodejs}" ] ++ npmFlagsYarn;

  commonEnv = {
    XDG_CONFIG_DIRS     = ".";
    NO_UPDATE_NOTIFIER  = true;
    installJavascript   = true;
  };

  commonBuildInputs = [ _nodejs makeWrapper ];  # TODO: git?

  # unpack the .tgz into output directory and add npm wrapper
  # TODO: "cd $out" vs NIX_NPM_BUILDPACKAGE_OUT=$out?
  untarAndWrap = name: cmds: ''
    mkdir -p $out/bin
    tar xzvf ./${name}.tgz -C $out --strip-components=1
    if [ "$installJavascript" = "1" ]; then
      cp -R node_modules $out/
      ${ concatStringsSep ";" (map (cmd:
        ''makeWrapper ${cmd} $out/bin/${baseNameOf cmd} --run "cd $out"''
      ) cmds) }
    fi
  '';

  yarnpkg-lockfile = fetchurl {
    name = "_yarnpkg_lockfile___lockfile_1.1.0.tgz";
    url  = "https://registry.yarnpkg.com/@yarnpkg/lockfile/-/lockfile-1.1.0.tgz";
    sha1 = "e77a97fbd345b76d83245edcd17d393b1b41fb31";
  };
in {
  buildNpmPackage = args @ {
    src, npmBuild ? "npm ci", npmBuildMore ? "",
    buildInputs ? [], npmFlags ? [], ...
  }:
    let
      info  = npmInfo src;
      lock  = fromJSON (readFile (src + "/package-lock.json"));
    in stdenv.mkDerivation ({
      inherit (info) name;
      inherit (info.info) version;

      preBuildPhases    = [ "npmCachePhase" ];
      preInstallPhases  = [ "npmPackPhase" ];

      npmCachePhase = ''
        addToSearchPath NODE_PATH ${npmModules}   # pacote
        node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock}
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

      installPhase = untarAndWrap info.name [npmCmd];
    } // commonEnv // args // {
      buildInputs = commonBuildInputs ++ buildInputs;
      npmFlags    = npmFlagsNpm ++ npmFlags;
    });

  buildYarnPackage = args @ {
    src, yarnBuild ? "yarn", yarnBuildMore ? "", integreties ? {},
    buildInputs ? [], yarnFlags ? [], npmFlags ? [], ...
  }:
    let
      info        = npmInfo src;
      deps        = { dependencies = fromJSON (readFile yarnJson); };
      yarnIntFile = writeText "integreties.json" (toJSON integreties);
      yarnLock    = src + "/yarn.lock";
      yarnJson    = runCommand "yarn.json" {} ''
        set -e
        mkdir -p node_modules/@yarnpkg/lockfile
        tar -C $_ --strip-components=1 -xf ${yarnpkg-lockfile}
        addToSearchPath NODE_PATH $PWD/node_modules         # @yarnpkg/lockfile
        addToSearchPath NODE_PATH ${npmModules}             # ssri
        ${_nodejs}/bin/node ${./mkyarnjson.js} ${yarnLock} ${yarnIntFile} > $out
      '';
    in stdenv.mkDerivation ({
      inherit (info) name;
      inherit (info.info) version;

      preBuildPhases    = [ "yarnConfigPhase" "yarnCachePhase" ];
      preInstallPhases  = [ "yarnPackPhase" ];

      # TODO
      yarnConfigPhase = ''
        cat <<-END >> .yarnrc
        	yarn-offline-mirror "$PWD/yarn-cache"
        	nodedir "${_nodejs}"
        END
      '';

      yarnCachePhase = ''
        mkdir -p yarn-cache
        node ${./mkyarncache.js} ${cacheInput "yarn-cache-input.json" deps}
      '';

      buildPhase = ''
        ${npmAlias}
        ${yarnAlias}
        runHook preBuild
        ${yarnBuild}
        ${yarnBuildMore}
        runHook postBuild
      '';

      # TODO: install --production?
      yarnPackPhase = ''
        ${yarnAlias}
        yarn pack --ignore-scripts --filename ${info.name}.tgz
      '';

      installPhase = untarAndWrap info.name [npmCmd yarnCmd];
    } // commonEnv // removeAttrs args [ "integreties" ] // {
      buildInputs = [ _yarn ] ++ commonBuildInputs ++ buildInputs;
      yarnFlags   = [ "--offline" "--frozen-lockfile" "--non-interactive" ] ++ yarnFlags;
      npmFlags    = npmFlagsYarn ++ npmFlags;
    });
}
