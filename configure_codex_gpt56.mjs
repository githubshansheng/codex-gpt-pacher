#!/usr/bin/env node

import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const MODEL_TIERS = {
  sol: ["gpt-5.6-sol", "GPT-5.6 Sol"],
  terra: ["gpt-5.6-terra", "GPT-5.6 Terra"],
  luna: ["gpt-5.6-luna", "GPT-5.6 Luna"],
}

const EFFORT_DESCRIPTIONS = {
  low: "Fast responses with lighter reasoning",
  medium: "Balances speed and reasoning depth for everyday tasks",
  high: "Greater reasoning depth for complex problems",
  xhigh: "Extra high reasoning depth for complex problems",
  max: "Maximum reasoning depth for the hardest problems",
  ultra: "Ultra parallel reasoning; requires explicit provider support",
}

function log(message) {
  console.log(`[codex-gpt56-config] ${message}`)
}

function fail(message) {
  throw new Error(message)
}

function timestamp() {
  const now = new Date()
  const pad = (value) => String(value).padStart(2, "0")
  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    "-",
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds()),
  ].join("")
}

function printHelp() {
  console.log(`Usage: node configure_codex_gpt56.mjs [options]

Configuration-only fallback for systems without Python.

Options:
  --catalog PATH                 Explicit model catalog path
  --tiers sol,terra,luna         Models to add or update
  --default-model keep|sol|terra|luna
                                 Default to GPT-5.6 Sol; use keep to preserve
  --enable-ultra                 Accepted for compatibility; Ultra is default
  --disable-ultra                Hide Ultra for providers that reject it
  --dry-run                      Report paths without writing
  --self-test                    Run an isolated configuration test
  --yes                          Accepted for launcher compatibility
  -h, --help                     Show this help

This helper updates only the model catalog and config.toml. It does not patch
Desktop app.asar, so account-side UI filtering may still show Custom.`)
}

function parseArgs(argv) {
  const options = {
    catalog: null,
    tiers: "sol,terra,luna",
    defaultModel: "sol",
    enableUltra: true,
    dryRun: false,
    selfTest: false,
  }

  const valueOptions = new Map([
    ["--catalog", "catalog"],
    ["--tiers", "tiers"],
    ["--default-model", "defaultModel"],
  ])
  const unsupportedDesktopOptions = new Set([
    "--app",
    "--output",
    "--desktop-only",
    "--verify-only",
  ])

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "-h" || argument === "--help") {
      printHelp()
      process.exit(0)
    }
    if (argument === "--enable-ultra") {
      options.enableUltra = true
      continue
    }
    if (argument === "--disable-ultra") {
      options.enableUltra = false
      continue
    }
    if (argument === "--dry-run") {
      options.dryRun = true
      continue
    }
    if (argument === "--self-test") {
      options.selfTest = true
      continue
    }
    if (argument === "--yes" || argument === "--catalog-only") continue
    if (unsupportedDesktopOptions.has(argument)) {
      fail(`${argument} requires the Python full-patch mode`)
    }
    const key = valueOptions.get(argument)
    if (key) {
      const value = argv[index + 1]
      if (!value || value.startsWith("--")) fail(`Missing value for ${argument}`)
      options[key] = value
      index += 1
      continue
    }
    fail(`Unknown option: ${argument}`)
  }
  return options
}

function expandPath(input) {
  let value = input
  if (value === "~") value = os.homedir()
  else if (value.startsWith(`~${path.sep}`) || value.startsWith("~/")) {
    value = path.join(os.homedir(), value.slice(2))
  }
  value = value.replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? "")
  if (process.platform === "win32") {
    value = value.replace(/%([^%]+)%/g, (_, name) => process.env[name] ?? "")
  }
  return path.resolve(value)
}

function codexHome() {
  return expandPath(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"))
}

function readText(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
}

function backupFile(file) {
  if (!fs.existsSync(file)) return null
  const backup = path.join(path.dirname(file), `${path.basename(file)}.backup-${timestamp()}`)
  fs.copyFileSync(file, backup)
  log(`Backup created: ${backup}`)
  return backup
}

function readCatalogSetting(configText) {
  const match = configText.match(/^\s*model_catalog_json\s*=\s*["']([^"']+)["']\s*$/m)
  return match?.[1] ?? null
}

function resolveCatalogPath(options, configPath) {
  if (options.catalog) return { catalogPath: expandPath(options.catalog), addSetting: false }
  const configured = readCatalogSetting(readText(configPath))
  if (configured) {
    const expanded = expandPath(configured)
    const catalogPath = path.isAbsolute(configured)
      ? expanded
      : path.resolve(path.dirname(configPath), configured)
    return { catalogPath, addSetting: false }
  }
  return {
    catalogPath: path.join(path.dirname(configPath), "model_catalog.json"),
    addSetting: true,
  }
}

function findCodexCli() {
  const command = process.platform === "win32" ? "where" : "which"
  const result = spawnSync(command, ["codex"], { encoding: "utf8", shell: false })
  if (result.status === 0) {
    const candidate = result.stdout.split(/\r?\n/).find(Boolean)
    if (candidate) return candidate.trim()
  }
  return null
}

function loadBaseCatalog(catalogPath, home) {
  if (fs.existsSync(catalogPath)) {
    return JSON.parse(fs.readFileSync(catalogPath, "utf8"))
  }

  const cache = path.join(home, "models_cache.json")
  if (fs.existsSync(cache)) {
    log(`Using model cache as catalog template: ${cache}`)
    return JSON.parse(fs.readFileSync(cache, "utf8"))
  }

  const cli = findCodexCli()
  if (cli) {
    const result = spawnSync(cli, ["debug", "models"], {
      encoding: "utf8",
      shell: process.platform === "win32" && /\.(cmd|bat)$/i.test(cli),
    })
    if (result.status === 0 && result.stdout.trim()) return JSON.parse(result.stdout)
  }

  fail(
    "No catalog, models_cache.json, or working Codex CLI was found. " +
      "Start Codex once or pass --catalog with an existing catalog JSON.",
  )
}

function selectTemplate(models) {
  for (const slug of ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex"]) {
    const model = models.find((candidate) => candidate.slug === slug)
    if (model) return model
  }
  const model = models.find((candidate) => Array.isArray(candidate.supported_reasoning_levels))
  if (!model) fail("The catalog has no reusable reasoning-model template")
  return model
}

function parseTiers(value) {
  const tiers = [...new Set(value.split(",").map((item) => item.trim().toLowerCase()).filter(Boolean))]
  const unknown = tiers.filter((tier) => !MODEL_TIERS[tier])
  if (unknown.length) fail(`Unknown GPT-5.6 tiers: ${unknown.join(", ")}`)
  return tiers
}

function effortOptions(enableUltra) {
  const efforts = ["low", "medium", "high", "xhigh", "max"]
  if (enableUltra) efforts.push("ultra")
  return efforts.map((effort) => ({
    effort,
    description: EFFORT_DESCRIPTIONS[effort],
  }))
}

function updateCatalog(data, tiers, enableUltra) {
  if (!data || !Array.isArray(data.models)) fail("Catalog JSON must contain a models array")
  const template = selectTemplate(data.models)
  let nextPriority =
    Math.max(1000, ...data.models.map((model) => model.priority).filter(Number.isInteger)) + 1

  for (const tier of tiers) {
    const [slug, displayName] = MODEL_TIERS[tier]
    let model = data.models.find((candidate) => candidate.slug === slug)
    if (!model) {
      model = structuredClone(template)
      model.priority = nextPriority
      nextPriority += 1
      data.models.push(model)
    }
    Object.assign(model, {
      slug,
      display_name: displayName,
      description: displayName,
      visibility: "list",
      supported_in_api: true,
      upgrade: null,
      supported_reasoning_levels: effortOptions(enableUltra),
    })
    log(`Prepared ${displayName}`)
  }
  return data
}

function setTomlValue(text, key, value) {
  const escaped = value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')
  const line = `${key} = "${escaped}"`
  const pattern = new RegExp(`^\\s*${key}\\s*=.*$`, "m")
  return pattern.test(text) ? text.replace(pattern, line) : `${line}\n${text}`
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function activeModelProvider(text) {
  const match = text.match(/^\s*model_provider\s*=\s*["']([^"']+)["']\s*$/m)
  return match?.[1] ?? null
}

function providerSectionBounds(text, provider) {
  const header = new RegExp(`^\\s*\\[model_providers\\.${escapeRegExp(provider)}\\]\\s*$`, "m")
  const match = header.exec(text)
  if (!match) return null
  const tail = text.slice(match.index + match[0].length)
  const nextSection = tail.match(/^\s*\[[^\]]+\]\s*$/m)
  const end = nextSection ? match.index + match[0].length + nextSection.index : text.length
  return [match.index, end]
}

function enableNoChatgptLoginMode(text) {
  const provider = activeModelProvider(text)
  if (!provider || new Set(["openai", "chatgpt"]).has(provider.toLowerCase())) {
    return { text, changed: false, provider: null }
  }
  const bounds = providerSectionBounds(text, provider)
  if (!bounds) fail(`Active model provider section was not found: [model_providers.${provider}]`)
  const [start, end] = bounds
  const section = text.slice(start, end)
  const baseMatch = section.match(/^\s*base_url\s*=\s*["']([^"']+)["']\s*$/m)
  if (baseMatch && /^https:\/\/api\.openai\.com(?:\/|$)/i.test(baseMatch[1])) {
    return { text, changed: false, provider: null }
  }
  const authPattern = /^(\s*requires_openai_auth\s*=\s*)(?:true|false)(\s*(?:#.*)?)$/m
  let updated
  if (authPattern.test(section)) {
    updated = section.replace(authPattern, "$1false$2")
  } else {
    const headerEnd = section.indexOf("\n")
    const insertion = headerEnd < 0 ? section.length : headerEnd + 1
    updated = `${section.slice(0, insertion)}requires_openai_auth = false\n${section.slice(insertion)}`
  }
  if (updated === section) return { text, changed: false, provider: null }
  return { text: `${text.slice(0, start)}${updated}${text.slice(end)}`, changed: true, provider }
}

function configure(options) {
  const home = codexHome()
  const configPath = path.join(home, "config.toml")
  const { catalogPath, addSetting } = resolveCatalogPath(options, configPath)
  const tiers = parseTiers(options.tiers)

  log(`Codex home: ${home}`)
  log(`Config: ${configPath}`)
  log(`Catalog: ${catalogPath}`)
  if (options.dryRun) {
    log("Dry run complete; no files were changed")
    return
  }

  fs.mkdirSync(home, { recursive: true })
  const catalog = updateCatalog(loadBaseCatalog(catalogPath, home), tiers, options.enableUltra)
  backupFile(catalogPath)
  fs.mkdirSync(path.dirname(catalogPath), { recursive: true })
  fs.writeFileSync(catalogPath, `${JSON.stringify(catalog, null, 2)}\n`, "utf8")

  let configText = readText(configPath)
  let configChanged = false
  if (addSetting) {
    configText = setTomlValue(configText, "model_catalog_json", catalogPath)
    configChanged = true
  }
  if (options.defaultModel !== "keep") {
    if (!MODEL_TIERS[options.defaultModel]) fail(`Invalid default model: ${options.defaultModel}`)
    configText = setTomlValue(configText, "model", MODEL_TIERS[options.defaultModel][0])
    configChanged = true
  }
  const noLoginResult = enableNoChatgptLoginMode(configText)
  configText = noLoginResult.text
  configChanged = configChanged || noLoginResult.changed
  if (configChanged) {
    backupFile(configPath)
    fs.writeFileSync(configPath, configText, "utf8")
    if (noLoginResult.changed) {
      log(`Enabled API-key/no-ChatGPT-login mode for provider: ${noLoginResult.provider}`)
    }
  }

  log(`Configuration update completed for: ${tiers.join(", ")}`)
  log("Desktop app.asar was not modified because Python is unavailable.")
  log("The backend catalog is ready, but Desktop may still display Custom until the full patch is run.")
}

function selfTest() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-gpt56-config-test-"))
  try {
    const home = path.join(root, ".codex")
    fs.mkdirSync(home, { recursive: true })
    const catalogPath = path.join(home, "catalog.json")
    const fixture = {
      models: [
        {
          slug: "gpt-5.5",
          display_name: "GPT-5.5",
          description: "GPT-5.5",
          visibility: "list",
          priority: 10,
          supported_in_api: true,
          supported_reasoning_levels: [
            { effort: "low", description: "low" },
            { effort: "medium", description: "medium" },
          ],
        },
      ],
    }
    fs.writeFileSync(catalogPath, JSON.stringify(fixture), "utf8")
    fs.writeFileSync(
      path.join(home, "config.toml"),
      `model_catalog_json = "${catalogPath.replaceAll("\\", "\\\\")}"\n` +
        'model_provider = "custom"\n' +
        '[model_providers.custom]\n' +
        'base_url = "https://third-party.example/v1"\n' +
        "requires_openai_auth = true\n",
      "utf8",
    )
    const previous = process.env.CODEX_HOME
    process.env.CODEX_HOME = home
    configure({
      catalog: null,
      tiers: "sol,terra",
      defaultModel: "sol",
      enableUltra: true,
      dryRun: false,
    })
    if (previous === undefined) delete process.env.CODEX_HOME
    else process.env.CODEX_HOME = previous

    const updated = JSON.parse(fs.readFileSync(catalogPath, "utf8"))
    for (const slug of ["gpt-5.6-sol", "gpt-5.6-terra"]) {
      const model = updated.models.find((candidate) => candidate.slug === slug)
      if (!model) fail(`Self-test missing ${slug}`)
      const efforts = model.supported_reasoning_levels.map((item) => item.effort)
      if (!efforts.includes("max") || !efforts.includes("ultra")) {
        fail(`Self-test reasoning efforts are wrong for ${slug}`)
      }
    }
    const configText = fs.readFileSync(path.join(home, "config.toml"), "utf8")
    if (!configText.includes('model = "gpt-5.6-sol"')) {
      fail("Self-test default model was not updated")
    }
    if (!configText.includes("requires_openai_auth = false")) {
      fail("Self-test no-login provider mode was not enabled")
    }
    log("Self-test passed")
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
}

try {
  const options = parseArgs(process.argv.slice(2))
  if (options.selfTest) selfTest()
  else configure(options)
} catch (error) {
  console.error(`[codex-gpt56-config] ERROR: ${error.message}`)
  process.exitCode = 1
}
