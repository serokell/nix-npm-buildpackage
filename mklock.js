const assert      = require("assert")
const fs          = require("fs")
const lockfile    = require("@yarnpkg/lockfile")
const semver      = require("semver")
const ssri        = require("ssri")

const USAGE       = "node mklock.js package-lock.json package.json yarn.lock integrities.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
  console.error("Usage:", USAGE)
  process.exit(1)
}

const [pkgLockFile, pkgFile, yarnLockFile, intFile] = process.argv.slice(2)

const pkgJson     = JSON.parse(fs.readFileSync(pkgFile, "utf8"))
const yarnJson    = lockfile.parse(fs.readFileSync(yarnLockFile, "utf8")).object
const integrities = intFile ? JSON.parse(fs.readFileSync(intFile)) : {}

const pkgDeps     = { ...(pkgJson.devDependencies || {}),
                      ...(pkgJson.dependencies    || {}) }

function objKeys(o) {
  const keys = Object.keys(o)
  keys.sort()
  return keys
}

function splitNameVsn(key) {
  // foo@vsn or @foo/bar@vsn
  if (key[0] == "@") {
    const [name, vsn] = key.slice(1).split("@")
    return ["@"+name, vsn]
  } else {
    return key.split("@")
  }
}

function addDeps(obj, pkg, vsn, seen) {
  const pkgvsn      = pkg + "@" + vsn
  if (seen[pkgvsn]) return  // break cycle
  seen[pkgvsn]      = true
  const pkgdeps     = deps[pkg][vsn]._dependencies || {}
  obj.requires      = {}
  obj.dependencies  = {}
  objKeys(pkgdeps).forEach(key => {
    const depvsn      = pkgdeps[key]
    const dep         = deps[key][depvsn]
    const ass         = !depsTree[key] ? depsTree :
                        depsTree[key].version != dep.version ?
                          obj.dependencies : null
    obj.requires[key] = depvsn
    if (ass) {
      const dep_ = { ...dep, _dependencies: undefined }
      ass[key] = dep_
      addDeps(dep_, key, depvsn, { ...seen })
    }
  })
}

const deps      = {}
const depsTree  = {}

objKeys(yarnJson).forEach(key => {
  const dep         = yarnJson[key]
  const [name, vsn] = splitNameVsn(key)
  const [url, sha1] = dep.resolved.split("#", 2)
  const integrity   = dep.integrity || integrities[url] ||
                      ssri.fromHex(sha1, "sha1").toString()
  assert(integrity, "missing integrity for " + JSON.stringify(dep))
  if (!deps[name]) deps[name] = {}
  deps[name][vsn]   = { version: dep.version, resolved: url,
                        integrity: integrity,
                        _dependencies: dep.dependencies }
})

objKeys(pkgDeps).forEach(key => {
  depsTree[key] = { ...deps[key][pkgDeps[key]], _dependencies: undefined }
})

objKeys(pkgDeps).forEach(key => {
  addDeps(depsTree[key], key, pkgDeps[key], {})
})

const lock = { name: pkgJson.name, version: pkgJson.version,
               lockfileVersion: 1, requires: true,
               dependencies: depsTree }

fs.writeFileSync(pkgLockFile, JSON.stringify(lock, null, 2))
