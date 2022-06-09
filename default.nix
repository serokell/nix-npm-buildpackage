{ writeShellScriptBin, writeText, runCommand, writeScriptBin, stdenv, lib
, fetchurl, makeWrapper, nodejs, yarn, jq }:
with lib;
let
  inherit (builtins) fromJSON toJSON split removeAttrs replaceStrings toFile;

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  depFetchOwn = { resolved, integrity, name ? null, ... }:
    let
      bname = baseNameOf resolved;
      fname = if hasSuffix ".tgz" bname || hasSuffix ".tar.gz" bname then
        bname
      else
        bname + ".tgz";
    in nameValuePair resolved {
      inherit name bname integrity;
      path = fetchurl {
        name = fname;
        url = resolved;
        hash = integrity;
      };
    };

  depToFetch = args@{ resolved ? null, dependencies ? { }, ... }:
    (optional (resolved != null) (depFetchOwn args))
    ++ (depsToFetches dependencies);

  cacheInput = oFile: iFile:
    writeText oFile (toJSON (listToAttrs (depToFetch iFile)));

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

  commonEnv = {
    XDG_CONFIG_DIRS = ".";
    NO_UPDATE_NOTIFIER = true;
    installJavascript = true;
  };

  commonBuildInputs = [ nodejs makeWrapper ]; # TODO: git?

  unScope = replaceStrings [ "@" "/" ] [ "" "-" ];

  # unpack the .tgz into output directory and add npm wrapper
  # TODO: "cd $out" vs NIX_NPM_BUILDPACKAGE_OUT=$out?
  untarAndWrap = name: cmds: ''
    shopt -s nullglob
    mkdir -p $out/bin
    tar xzvf ${unScope name}.tgz -C $out --strip-components=1
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
  mkNodeModules = { src, extraEnvVars ? { }, pname, version, buildInputs ? [] }:
    let
      packageJson = src + "/package.json";
      packageLockJson = src + "/package-lock.json";
      info = fromJSON (readFile packageJson);
      lock = fromJSON (readFile packageLockJson);
    in
      assert asserts.assertMsg (versionAtLeast nodejs.version "10.20.0") "nix-npm-buildPackages requires at least npm v6.13.5";
      # TODO: this *could* work with some more debugging
      assert asserts.assertMsg (versionAtLeast nodejs.version "16" -> lock.lockfileVersion >= 2) "node v16 requires lockfile v2 (run npm once)";
      # TODO: lock file version 3
      assert asserts.assertMsg (lock.lockfileVersion <= 2) "nix-npm-buildPackage doesn't support this lock file version";
      stdenv.mkDerivation ({
      name = "${pname}-${version}-node-modules";

      buildInputs = [ nodejs jq ] ++ buildInputs;

      npm_config_cache = "./npm-cache";
      npm_config_nodejs = "${nodejs}";
      npm_config_offline = true;
      npm_config_script_shell = "${shellWrap}/bin/npm-shell-wrap.sh";
      npm_config_update_notifier = false;

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
        node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock}

        echo 'building node_modules'
        npm ci
        patchShebangs ./node_modules/

        mkdir $out
        mv ./node_modules $out/
        # add npm-cache because npm prune wants to change some pkgs
        mv ./npm-cache $out/
        # npm wants to write to this cache
        rm -rf $out/npm-cache/{_cacache/tmp,_locks}
        ln -s /tmp $out/npm-cache/_cacache/tmp
        ln -s /tmp $out/npm-cache/_locks
      '';
    } // extraEnvVars);

  buildNpmPackage = args@{ src, npmBuild ? ''
    # this is what npm runs by default, only run when it exists
    ${jq}/bin/jq -e '.scripts.prepublish' package.json >/dev/null && npm run prepublish
    ${jq}/bin/jq -e '.scripts.prepare' package.json >/dev/null && npm run prepare
  '', buildInputs ? [ ], extraEnvVars ? { }
    , extraNodeModulesArgs ? {}
    , # environment variables passed through to `npm ci`
    ... }:
    let
      inherit (npmInfo src) pname version;
      nodeModules = mkNodeModules ({
        inherit src extraEnvVars pname version;
      } // extraNodeModulesArgs);
    in
      assert asserts.assertMsg (!(args ? packageOverrides)) "buildNpmPackage-packageOverrides is no longer supported";
      stdenv.mkDerivation ({
      inherit pname version;

      configurePhase = ''
        runHook preConfigure
        export HOME=$(mktemp -d)
        chmod a-w "$HOME"

        if [[ -e ./node_modules ]]; then
          echo 'WARNING: node_modules directory already exists, removing it'
          rm -rf ./node_modules
        fi

        patchShebangs .

        cp --reflink=auto -r ${nodeModules}/node_modules ./node_modules
        chmod -R u+w ./node_modules
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        ${npmBuild}
        runHook postBuild
      '';

      dontNpmPrune = false;

      installPhase = ''
        runHook preInstall
        if [ -z "''${dontNpmPrune-}" ]; then
          echo "running npm prune --production"
          npm prune --production
        fi
        npm pack --ignore-scripts
        ${untarAndWrap "${pname}-${version}" [ "${nodejs}/bin/npm" ]}
        runHook postInstall
      '';
      npm_config_offline = true;
      npm_config_update_notifier = false;
      # npm prune actually installs some packages sometimes
      npm_config_cache = "${nodeModules}/npm-cache";

      passthru = { inherit nodeModules; };
    } // commonEnv // extraEnvVars
      // removeAttrs args [ "extraEnvVars" "extraNodeModulesArgs" ] // {
        buildInputs = commonBuildInputs ++ buildInputs;
        passthru = { inherit nodeModules; } // (args.passthru or {});
      });

  buildYarnPackage = import ./buildYarnPackage.nix {
    inherit lib npmInfo runCommand fetchurl npmModules writeScriptBin nodejs
      yarn patchShebangs writeText stdenv untarAndWrap depToFetch commonEnv
      makeWrapper writeShellScriptBin unScope;
  };
}
