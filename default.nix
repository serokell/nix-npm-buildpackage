{ writeShellScriptBin, writeText, runCommand, writeScriptBin,
  stdenv, fetchurl, makeWrapper, nodejs, yarn, jq, gnutar }:
with stdenv.lib; let
  inherit (builtins) fromJSON toJSON split removeAttrs toFile;

  _nodejs = nodejs;
  _yarn   = yarn.override { nodejs = _nodejs; };

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  makeTarball = name: path: runCommand "${name}.tar.gz" {
    buildInputs = [ gnutar ];
  } ''
    cp -R "${path}" package
    tar -caf $out package
  '';

  depFetchOwn = args:
    let
      uri       = args.resolved or args.version;
      parsedURI = splitString "://" uri;
      parsedPath= splitString "#" uri;
      parsedFrom= splitString "#" args.from;
      rev       = elemAt parsedPath 1;
      ref       = if builtins.length parsedFrom > 1 then elemAt parsedFrom 1 else "master";
      protocol  = elemAt parsedURI 0;
      ssri      = split "-" args.integrity;
      hashType  = head ssri;
      hash      = elemAt ssri 2;
      bname     = baseNameOf uri;
      fname     = if hasSuffix ".tgz" bname || hasSuffix ".tar.gz" bname
                  then bname else bname + ".tgz";
      path      = if hasInfix "git" protocol
                  then makeTarball (args.name or "source") (builtins.fetchGit { url = uri; inherit ref rev; })
                  else if args ? integrity
                  then fetchurl { name = fname; url = uri; "${hashType}" = hash; }
                  else throw "Unsupported dependency ${uri} (${args.name or "no name"})";

    in nameValuePair uri { name = args.name or null; inherit bname path; };

  overrideTgz = src: runCommand "${src.name}.tgz" {} ''
    cp -r --reflink=auto ${src} ./package
    chmod +w ./package ./package/package.json
    # scripts are not supported
    ${jq}/bin/jq '.scripts={}' ${src}/package.json > ./package/package.json
    tar --sort=name --owner=0:0 --group=0:0 --mtime='UTC 2019-01-01' -czf $out package
  '';

  overrideToFetch = pkg: { path = "${overrideTgz pkg}"; };

  depToFetch = args @ { dependencies ? {}, ... }:
    (optional ((args ? resolved || args ? version) && (args ? integrity || args ? from)) (depFetchOwn args)) ++ (depsToFetches dependencies);

  cacheInput = oFile: iFile: overrides:
    writeText oFile (toJSON ((listToAttrs (depToFetch iFile))
      // (builtins.mapAttrs (_: overrideToFetch) overrides)));

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
    "--cache=${
      # `npm ci` had been treating `cache` parameter incorrently since npm 6.11.3, it was fixed in 6.13.5
      # https://github.com/npm/cli/pull/550
      if versionAtLeast _nodejs.version "10.17.0" && !(versionAtLeast _nodejs.version "10.20.0")
      then "./npm-cache/_cacache"
      else "./npm-cache"
    }"
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
  mkNodeModules = { src, packageOverrides, extraEnvVars ? {}, pname, version }:
    let
      packageJson = src + /package.json;
      packageLockJson = src + /package-lock.json;
      info = fromJSON (readFile packageJson);
      lock = fromJSON (readFile packageLockJson);
    in stdenv.mkDerivation ({
      name = "${pname}-${version}-node-modules";

      buildInputs = [ _nodejs jq ];

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
        NODE_PATH=${npmModules} node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock packageOverrides}

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
      packageOverrides ? {},
    extraEnvVars ? {}, # environment variables passed through to `npm ci`
    ...
  }:
    let
      info = fromJSON (readFile (src + /package.json));
      pname = info.name or "unknown-node-package";
      version = info.version or "unknown";
      nodeModules = mkNodeModules { inherit src packageOverrides extraEnvVars pname version; };
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
        ${untarAndWrap "${pname}-${version}" [npmCmd]}
        runHook postInstall
      '';
    } // commonEnv // extraEnvVars // removeAttrs args [ "extraEnvVars" "packageOverrides" ] // {
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
        node ${./mkyarncache.js} ${cacheInput "yarn-cache-input.json" deps {}}
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
