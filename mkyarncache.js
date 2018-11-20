const fs            = require("fs")
const path          = require("path")

const USAGE         = "node mkyarncache.js yarn-cache-input.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
  console.error("Usage:", USAGE)
  process.exit(1)
}

const [nixPkgsFile] = process.argv.slice(2)

const yarnCacheDir  = "./yarn-cache"
const nixPkgs       = JSON.parse(fs.readFileSync(nixPkgsFile, "utf8"))

function name(dep) {
  return dep.name[0] == "@" ? dep.name.split("/")[0] + "-" + dep.bname : dep.bname
}

Object.keys(nixPkgs).forEach(url => {
  const dep = nixPkgs[url];
  fs.symlinkSync(dep.path, path.join(yarnCacheDir, name(dep)))
})
