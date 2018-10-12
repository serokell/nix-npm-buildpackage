const assert        = require('assert')
const fs            = require('fs')
const lockfile      = require("@yarnpkg/lockfile")
const semver        = require('semver')

let pkgLockFile     = process.argv[2]
let pkgJsonFile     = process.argv[3]
let yarnLockFile    = process.argv[4]
let intFile         = process.argv[5]

let pkgData         = fs.readFileSync(pkgJsonFile, 'utf8')
let yarnData        = fs.readFileSync(yarnLockFile, 'utf8')
let pkgJson         = JSON.parse(pkgData)
let yarnJson        = lockfile.parse(yarnData).object
let integrities     = intFile ? JSON.parse(fs.readFileSync(intFile)) : {}

let pkgDeps         = { ...(pkgJson.devDependencies || {}),
                        ...(pkgJson.dependencies    || {}) }

function splitNameVsn (key) {
  if (key[0] == "@") {
    let [name, vsn] = key.slice(1).split("@")
    return ["@"+name, vsn]
  } else {
    return key.split("@")
  }
}

function addDeps(obj, pkg, vsn, seen) {
  if (seen[pkg + "@" + vsn]) return // loop
  seen[pkg + "@" + vsn] = true
  let pkgdeps           = deps[pkg][vsn]._dependencies || {}
  obj.dependencies      = {}
  Object.keys(pkgdeps).forEach(key => {
    let depvsn            = pkgdeps[key]
    obj.dependencies[key] = {...deps[key][depvsn]}
    addDeps(obj.dependencies[key], key, depvsn, {...seen})
  })
}

let deps = {}
Object.keys(yarnJson).forEach(key => {
  let dep         = yarnJson[key]
  let [name, vsn] = splitNameVsn(key)
  let [url, sha1] = dep.resolved.split("#", 2)
  if (!sha1 && integrities[url]) sha1 = integrities[url]
  assert(sha1, "missing sha1 for " + JSON.stringify(dep)) // TODO
  if (!deps[name]) deps[name] = {}
  deps[name][vsn] = { version: dep.version, resolved: url,
                      integrity: "sha1-" + sha1,
                      _dependencies: dep.dependencies }
})

let depsTree = {}
Object.keys(pkgDeps).forEach(key => {
  let vsn       = pkgDeps[key]
  depsTree[key] = {...deps[key][vsn]}
  addDeps(depsTree[key], key, vsn, {})
})

// NB: dependencies flattened by yarn; should work!
let lock = { name: pkgJson.name, version: pkgJson.version,
             lockfileVersion: 1, requires: true,
             dependencies: depsTree }

fs.writeFileSync(pkgLockFile, JSON.stringify(lock, null, 2))
