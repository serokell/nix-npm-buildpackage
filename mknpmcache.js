const fs = require("fs")
const path = require("path")
const cacache_index = require("cacache/lib/entry-index.js")
const cacache_content_path = require("cacache/lib/content/path.js")

const USAGE = "node mknpmcache.js npm-cache-input.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
    console.error("Usage:", USAGE)
    process.exit(1)
}

const [nixPkgsFile] = process.argv.slice(2)

const nixPkgs = JSON.parse(fs.readFileSync(nixPkgsFile, "utf8"))

async function main(nix, cache) {
    const cache_contains = new Set();
    const promises = Object.values(nix).map(async function({path: source, integrity}) {
        // check for duplicate entry
        if (cache_contains.has(integrity)) return;
        cache_contains.add(integrity);
        const {size} = await fs.promises.stat(source);
        const cachePath = cacache_content_path(cache, integrity);
        await fs.promises.mkdir(path.dirname(cachePath), {recursive: true});
        // TODO: symlink after https://github.com/npm/cacache/pull/114
        // await fs.promises.symlink(source, cachePath);
        await fs.promises.copyFile(source, cachePath, fs.constants.FICLONE);
        await cacache_index.insert(cache, `pacote:tarball:file:${source}`, integrity, {size})
    })
    await Promise.all(promises)
}

process.on("unhandledRejection", error => {
    console.log("unhandledRejection", error.message)
    process.exit(1)
})

main(nixPkgs, "./npm-cache/_cacache")
