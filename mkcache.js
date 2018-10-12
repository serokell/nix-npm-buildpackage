const assert  = require('assert')
const fs      = require('fs')
const path    = require('path')
const pacote  = require('pacote')

function traverseDeps(pkg, fn) {
  Object.values(pkg.dependencies).forEach(dep => {
    if (dep.resolved && dep.integrity) fn(dep)
    if (dep.dependencies) traverseDeps(dep, fn)
  })
}

function main(lockfile, nix, cache) {
  let hashes = new Map(Object.keys(nix).map(url => {
    let tar = nix[url]
    let manifest = pacote.manifest(tar, {offline: true, cache})
    return [url, manifest._integrity]
  }))
  traverseDeps(lockfile, dep => {
    if (dep.integrity.startsWith("sha1-")) {
      assert(hashes.has(dep.resolved))
      dep.integrity = hashes.get(dep.resolved)
    } else {
      assert(dep.integrity == hashes.get(dep.resolved))
    }
  })
  // TODO: why?
  // fs.writeFileSync(pkgLockFile, JSON.stringify(lock, null, 4))
}

let nixPkgsFile     = process.argv[2]

const pkgLockFile   = "./package-lock.json"
const lock          = JSON.parse(fs.readFileSync(pkgLockFile, 'utf8'))
const nixPkgs       = JSON.parse(fs.readFileSync(nixPkgsFile, 'utf8'))

main(lock, nixPkgs, './npm-cache/_cacache')
