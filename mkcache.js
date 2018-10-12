const assert = require('assert')
const fs     = require('fs')
const path   = require('path')
const {promisify} = require('util')

// find pacote from npm dependencies
module.paths.push(path.join(process.argv[0], "../../lib/node_modules/npm/node_modules"))
const pacote = require('pacote')

function traverseDeps(pkg, fn) {
    Object.values(pkg.dependencies).forEach(dep => {
        if (dep.resolved && dep.integrity) fn(dep)
        if (dep.dependencies) traverseDeps(dep, fn)
    })
}

async function main(lockfile, nix, cache) {
    var promises = Object.keys(nix).map(async function(url) {
        var tar = nix[url]
        const manifest = await pacote.manifest(tar, {offline: true, cache})
        return [url, manifest._integrity]
    })
    var hashes = new Map(await Promise.all(promises))
    traverseDeps(lockfile, dep => {
        if (dep.integrity.startsWith("sha1-")) {
            assert(hashes.has(dep.resolved))
            dep.integrity = hashes.get(dep.resolved)
        }
        else {
            assert(dep.integrity == hashes.get(dep.resolved))
        }
    })
    await promisify(fs.writeFile)("./package-lock.json", JSON.stringify(lock, null, 4))
}
const lock = JSON.parse(fs.readFileSync('./package-lock.json', 'utf8'))
const nix_pkgs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
main(lock, nix_pkgs, './npm-cache/_cacache')

