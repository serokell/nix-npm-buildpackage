{ writeShellScriptBin, writeText, runCommand, writeScriptBin,
  stdenv, fetchurl, makeWrapper, nodejs-10_x, yarn, jq }:
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
    source ${stdenv}/setup
    patchShebangs "$@"
  '';

  shellWrap = writeShellScriptBin "npm-shell-wrap.sh" ''
    set -e
    pushd ''${PWD%%node_modules*}/node_modules
      ${patchShebangs}/bin/patchShebangs.sh .
    popd
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
  npmFlagsNpm   = [
    # `npm ci` treats cache parameter differently since npm 6.11.3:
    "--cache=${if versionAtLeast _nodejs.version "10.17.0" then "./npm-cache/_cacache" else "./npm-cache"}"
    "--nodedir=${_nodejs}"
    "--no-update-notifier"
  ] ++ npmFlagsYarn;

  commonEnv = {
    XDG_CONFIG_DIRS     = ".";
    NO_UPDATE_NOTIFIER  = true;
    installJavascript   = true;
  };

  commonBuildInputs = [ _nodejs makeWrapper ];  # TODO: git?

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
        makeWrapper ${_nodejs}/bin/node $out/bin/$(basename $i .js) \
          --add-flags $i --run "cd $out"
      done
      ${ concatStringsSep ";" (map (cmd:
        ''makeWrapper ${cmd} $out/bin/${baseNameOf cmd} --run "cd $out" --prefix PATH : ${stdenv.shellPackage}/bin''
      ) cmds) }
    fi
  '';

  yarnpkg-lockfile = fetchurl {
    name = "_yarnpkg_lockfile___lockfile_1.1.0.tgz";
    url  = "https://registry.yarnpkg.com/@yarnpkg/lockfile/-/lockfile-1.1.0.tgz";
    sha1 = "e77a97fbd345b76d83245edcd17d393b1b41fb31";
  };
in rec {
  mkNodeModules = { src, extraEnvVars ? {} }:
    let
      # filter out everything except package.json and package-lock.json if possible
      # allows to avoid rebuilding node_modules if these two files didn't change
      filteredSrc =
        let
          origSrc = if src ? _isLibCleanSourceWith then src.origSrc else src;
          getRelativePath = path: removePrefix (toString origSrc + "/") path;
          usedPaths = [ "package.json" "package-lock.json" ];
          cleanedSource = cleanSourceWith {
            src = src;
            filter = path: type: elem (getRelativePath path) usedPaths;
          };
        in if canCleanSource src then cleanedSource else src;

      packageJson = filteredSrc + "/package.json";
      packageLockJson = filteredSrc + "/package-lock.json";
      info = fromJSON (readFile packageJson);
      lock = fromJSON (readFile packageLockJson);
    in stdenv.mkDerivation ({
      name = "${info.name}-${info.version}-node-modules";

      buildInputs = [ _nodejs jq ];

      npmFlags = npmFlagsNpm;
      buildCommand = ''
        # Inside nix-build sandbox $HOME points to a non-existing
        # directory, but npm may try to create this directory (e.g.
        # when you run `npm install` or `npm prune`) and will succeed
        # if you have a single-user nix installation (because / is
        # writable in this case), causing different behavior for
        # single-user and multi-user nix. Create read-only $HOME to
        # prevent it
        mkdir -p --mode=a-w "$HOME"

        # do not run the toplevel lifecycle scripts, we only do dependencies
        jq '.scripts={}' ${packageJson} > ./package.json
        cp ${packageLockJson} ./package-lock.json

        echo 'building npm cache'
        chmod u+w ./package-lock.json
        NODE_PATH=${npmModules} node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock}

        echo 'building node_modules'
        npm $npmFlags ci
        patchShebangs ./node_modules/

        mkdir $out
        mv ./node_modules $out/
      '';
    } // extraEnvVars);

  buildNpmPackage = args @ {
    src, npmBuild ? ''
        # this is what npm runs by default, only run when it exists
        ${jq}/bin/jq -e '.scripts.prepublish' package.json >/dev/null && npm run prepublish
        ${jq}/bin/jq -e '.scripts.prepare' package.json >/dev/null && npm run prepare
    '', buildInputs ? [],
    extraEnvVars ? {}, # environment variables passed through to `npm ci`
    ...
  }:
    let
      info = fromJSON (readFile (src + "/package.json"));
      name = "${info.name}-${info.version}";
      nodeModules = mkNodeModules { inherit src extraEnvVars; };
    in stdenv.mkDerivation ({
      inherit name;

      configurePhase = ''
        mkdir -p --mode=a-w "$HOME"

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
        ${untarAndWrap name [npmCmd]}
        runHook postInstall
      '';
    } // commonEnv // extraEnvVars // removeAttrs args [ "extraEnvVars" ] // {
      buildInputs = commonBuildInputs ++ buildInputs;
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

      installPhase = ''
        runHook preInstall
        ${untarAndWrap info.name [npmCmd yarnCmd]}
        runHook postInstall
      '';
    } // commonEnv // removeAttrs args [ "integreties" ] // {
      buildInputs = [ _yarn ] ++ commonBuildInputs ++ buildInputs;
      yarnFlags   = [ "--offline" "--frozen-lockfile" "--non-interactive" ] ++ yarnFlags;
      npmFlags    = npmFlagsYarn ++ npmFlags;
    });
}
