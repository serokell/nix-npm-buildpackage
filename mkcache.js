const assert  = require("assert")
const fs      = require("fs")
const pacote  = require("pacote")
const path    = require("path")

// Usage: node mkcache.js npm-cache-input.json

let nixPkgsFile = process.argv[2]

function traverseDeps(pkg, fn) {
  Object.values(pkg.dependencies).forEach(dep => {
    if (dep.resolved && dep.integrity) fn(dep)
    if (dep.dependencies) traverseDeps(dep, fn)
  })
}

async function main(lockfile, nix, cache) {
  let promises = Object.keys(nix).map(async function (url) {
    let tar       = nix[url]
    let manifest  = await pacote.manifest(tar, { offline: true, cache })
    return [url, manifest._integrity]
  })
  let hashes = new Map(await Promise.all(promises))
  traverseDeps(lockfile, dep => {
    if (dep.integrity.startsWith("sha1-")) {
      assert(hashes.has(dep.resolved))
      dep.integrity = hashes.get(dep.resolved)
    } else {
      assert(dep.integrity == hashes.get(dep.resolved))
    }
  })
  // rewrite lock file to use sha512 hashes from pacote
  fs.writeFileSync(pkgLockFile, JSON.stringify(lock, null, 2))
}

const pkgLockFile   = "./package-lock.json"
const lock          = JSON.parse(fs.readFileSync(pkgLockFile, "utf8"))
const nixPkgs       = JSON.parse(fs.readFileSync(nixPkgsFile, "utf8"))

main(lock, nixPkgs, "./npm-cache/_cacache")
