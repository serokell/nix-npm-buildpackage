const assert        = require("assert")
const fs            = require("fs")
const pacote        = require("pacote")

const USAGE         = "node mknpmcache.js npm-cache-input.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
  console.error("Usage:", USAGE)
  process.exit(1)
}

const [nixPkgsFile] = process.argv.slice(2)

const pkgLockFile   = "./package-lock.json"
const lock          = JSON.parse(fs.readFileSync(pkgLockFile, "utf8"))
const nixPkgs       = JSON.parse(fs.readFileSync(nixPkgsFile, "utf8"))

function traverseDeps(pkg, fn) {
    Object.entries(pkg.dependencies).forEach(([name, dep]) => {
    fn(name, dep)
    if (dep.dependencies) traverseDeps(dep, fn)
  })
}

async function main(lockfile, nix, cache) {
  const promises = Object.keys(nix).map(async function (url) {
    const tar       = nix[url].path
    const manifest  = await pacote.manifest(tar, { offline: true, cache })
    return [url, manifest._integrity]
  })
  const hashes = new Map(await Promise.all(promises))
    traverseDeps(lockfile, (name, dep) => {
    if (hashes.has(name)) {
      console.log("overriding package", name)
      dep.integrity = hashes.get(name)
      return
    }
    let id = dep.resolved || dep.version;
        if ((dep.from && dep.from.includes("git")) || (dep.integrity && ! dep.integrity.startsWith("sha512-"))) {
      assert(hashes.has(id))
      dep.integrity = hashes.get(id)
    } else {
      assert(dep.integrity == hashes.get(id))
    }
  })
  // rewrite lock file to use sha512 hashes from pacote and overrides
  fs.writeFileSync(pkgLockFile, JSON.stringify(lockfile, null, 2))
}

process.on("unhandledRejection", error => {
  console.log("unhandledRejection", error.message)
  process.exit(1)
})

main(lock, nixPkgs, "./npm-cache/_cacache")
