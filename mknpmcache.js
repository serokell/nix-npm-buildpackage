const assert = require("assert")
const fs = require("fs")
const pacote = require("pacote")

const USAGE = "node mknpmcache.js npm-cache-input.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
    console.error("Usage:", USAGE)
    process.exit(1)
}

const [nixPkgsFile] = process.argv.slice(2)

const pkgLockFile = "./package-lock.json"
const lock = JSON.parse(fs.readFileSync(pkgLockFile, "utf8"))
const nixPkgs = JSON.parse(fs.readFileSync(nixPkgsFile, "utf8"))

// "node_modules/fsevents/node_modules/@asdf/g" -> "@asdf/g"
function baseNameOf(pkgName) {
    const entries = pkgName.split('node_modules/')
    return entries[entries.length - 1]
}

function traverseDeps(pkg, fn) {
    Object.entries(pkg.dependencies).forEach(([name, dep]) => {
        fn(name, dep)
        if (dep.dependencies) traverseDeps(dep, fn)
    })
}

async function main(lockfile, nix, cache) {
    const promises = Object.keys(nix).map(async function(url) {
        const tar = nix[url].path
        const manifest = await pacote.manifest(tar, {
            offline: true,
            cache
        })
        return [url, manifest._integrity]
    })
    const hashes = new Map(await Promise.all(promises))
    const traverseFn = (name, dep) => {
        if (hashes.has(baseNameOf(name))) {
            console.log("overriding package", name)
            dep.integrity = hashes.get(name)
            return
        }
        if (!dep.integrity || !dep.resolved) {
            return
        }
        if (dep.integrity.startsWith("sha1-")) {
            assert(hashes.has(dep.resolved))
            dep.integrity = hashes.get(dep.resolved)
        } else {
            assert(dep.integrity == hashes.get(dep.resolved))
        }
    };
    if (lockfile.dependencies)
        traverseDeps(lockfile, traverseFn)
    if (lockfile.packages)
        for (const [name, dep] of Object.entries(lockfile.packages))
            traverseFn(name, dep)
    // rewrite lock file to use sha512 hashes from pacote and overrides
    fs.writeFileSync(pkgLockFile, JSON.stringify(lockfile, null, 2))
}

process.on("unhandledRejection", error => {
    console.log("unhandledRejection", error.message)
    process.exit(1)
})

main(lock, nixPkgs, "./npm-cache/_cacache")
