const assert        = require("assert")
const fs            = require("fs")
const lockfile      = require("@yarnpkg/lockfile")
const ssri          = require("ssri")

const USAGE         = "node mkyarnjson.js integrities.json"

if (process.argv.length != USAGE.split(/\s+/).length) {
  console.error("Usage:", USAGE)
  process.exit(1)
}

const [intFile]     = process.argv.slice(2)
const yarnLockFile  = "./yarn.lock"

const yarnJson      = lockfile.parse(fs.readFileSync(yarnLockFile, "utf8")).object
const integrities   = JSON.parse(fs.readFileSync(intFile))
￼
function splitNameVsn(key) {
  // foo@vsn or @foo/bar@vsn
  if (key[0] == "@") {
    const [name, vsn] = key.slice(1).split("@")
    return ["@"+name, vsn]
  } else {
    return key.split("@")
  }
}

function processDeps(deps, result = {}) {
  objKeys(deps).forEach(key => {
    if (key in result) return
    const dep         = yarnJson[key]
    const [name, vsn] = splitNameVsn(key)
    const [url, sha1] = dep.resolved.split("#", 2)
    const integrity   = dep.integrity || integrities[url] ||
                        ssri.fromHex(sha1, "sha1").toString()
    assert(integrity, "missing integrity for " + JSON.stringify(dep))
    result[key]       = { resolved: url, integrity: integrity }
    if (dep.dependencies) processDeps(dep.dependencies, result)
  }
})

console.log(JSON.stringify(processDeps(yarnJson), null, 2))
