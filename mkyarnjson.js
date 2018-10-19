const assert        = require("assert")
const fs            = require("fs")
const lockfile      = require("@yarnpkg/lockfile")
const ssri          = require("ssri")

const USAGE         = "node mkyarnjson.js yarn.lock integrities.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
  console.error("Usage:", USAGE)
  process.exit(1)
}

const [yarnLockFile, intFile] = process.argv.slice(2)

const yarnJson      = lockfile.parse(fs.readFileSync(yarnLockFile, "utf8")).object
const integrities   = JSON.parse(fs.readFileSync(intFile))

function splitNameVsn(key) {
  // foo@vsn or @foo/bar@vsn
  if (key[0] == "@") {
    const [name, vsn] = key.slice(1).split("@")
    return ["@"+name, vsn]
  } else {
    return key.split("@")
  }
}

const deps = {}

Object.keys(yarnJson).forEach(key => {
  if (key in deps) return
  const dep         = yarnJson[key]
  const [name, vsn] = splitNameVsn(key)
  const [url, sha1] = dep.resolved.split("#", 2)
  const integrity   = dep.integrity || integrities[url] ||
                      (sha1 && ssri.fromHex(sha1, "sha1").toString())
  assert(integrity, "missing integrity for " + JSON.stringify(dep))
  deps[key]         = { resolved: url, integrity: integrity }
})

console.log(JSON.stringify(deps, null, 2))
