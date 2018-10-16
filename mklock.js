const assert        = require("assert")
const fs            = require("fs")
const lockfile      = require("@yarnpkg/lockfile")
const semver        = require("semver")
const ssri          = require("ssri")

// Usage: node mklock.js package-lock.json package.json yarn.lock integrities.json

let pkgLockFile     = process.argv[2]
let pkgFile         = process.argv[3]
let yarnLockFile    = process.argv[4]
let intFile         = process.argv[5]

let pkgJson         = JSON.parse(fs.readFileSync(pkgFile, "utf8"))
let yarnJson        = lockfile.parse(fs.readFileSync(yarnLockFile, "utf8")).object
let integrities     = intFile ? JSON.parse(fs.readFileSync(intFile)) : {}

let pkgDeps         = { ...(pkgJson.devDependencies || {}),
                        ...(pkgJson.dependencies    || {}) }

function objKeys(o) {
  let keys = Object.keys(o)
  keys.sort()
  return keys
}

function splitNameVsn(key) {
  // foo@vsn or @foo/bar@vsn
  if (key[0] == "@") {
    let [name, vsn] = key.slice(1).split("@")
    return ["@"+name, vsn]
  } else {
    return key.split("@")
  }
}

function addDeps(obj, pkg, vsn, seen) {
  let pkgvsn            = pkg + "@" + vsn
  if (seen[pkgvsn]) return  // break cycle
  seen[pkgvsn] = true
  let pkgdeps           = deps[pkg][vsn]._dependencies || {}
  obj.requires          = {}
  obj.dependencies      = {}
  objKeys(pkgdeps).forEach(key => {
    let depvsn            = pkgdeps[key]
    let dep               = deps[key][depvsn]
    let dep_              = { ...dep, _dependencies: undefined }
    obj.requires[key]     = depvsn
    if (!depsTree[key]) {
      depsTree[key]         = dep_
    } else if (depsTree[key].version != dep.version) {
      obj.dependencies[key] = dep_
    } else {
      return
    }
    addDeps(dep_, key, depvsn, { ...seen })
  })
}

let deps = {}
objKeys(yarnJson).forEach(key => {
  let dep         = yarnJson[key]
  let [name, vsn] = splitNameVsn(key)
  let [url, sha1] = dep.resolved.split("#", 2)
  let integrity   = dep.integrity || integrities[url] || ssri.fromHex(sha1, "sha1").toString()
  assert(integrity, "missing integrity for " + JSON.stringify(dep))
  if (!deps[name]) deps[name] = {}
  deps[name][vsn] = { version: dep.version, resolved: url,
                      integrity: integrity,
                      _dependencies: dep.dependencies }
})

let depsTree = {}
objKeys(pkgDeps).forEach(key => {
  let vsn       = pkgDeps[key]
  depsTree[key] = { ...deps[key][vsn], _dependencies: undefined }
  addDeps(depsTree[key], key, vsn, {})
})

let lock = { name: pkgJson.name, version: pkgJson.version,
             lockfileVersion: 1, requires: true,
             dependencies: depsTree }

fs.writeFileSync(pkgLockFile, JSON.stringify(lock, null, 2))
