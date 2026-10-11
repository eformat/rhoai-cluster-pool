const port = process.env.PORT || 8080
const express = require('express')
const path = require('path')
const fs = require('fs/promises')
const os = require('os')
const { spawn } = require('child_process')
const dotenv = require('dotenv')

// Load local env defaults (for dev/testing). In OpenShift, you typically set env vars on the Deployment.
dotenv.config({ path: process.env.ENV_FILE || path.join(__dirname, 'hive-ui.env') })
dotenv.config() // also allow standard .env if present

const app = express()

// Accept JSON POSTs from the UI (pull secret + install-config can be large)
app.use(express.json({ limit: '2mb' }))
app.use(express.static(__dirname))

function truncate(s, max = 64 * 1024) {
  if (!s) return ''
  if (s.length <= max) return s
  return s.slice(0, max) + `\n... truncated (${s.length - max} chars)`
}

function envSubst(input, vars) {
  // Supports $VAR and ${VAR}
  return input.replace(/\$(\w+)|\$\{(\w+)\}/g, (_m, v1, v2) => {
    const key = v1 || v2
    const val = vars[key]
    return val === undefined || val === null ? '' : String(val)
  })
}

async function configureHiveTenantsRoadshow(params) {
  const repoRoot = process.env.REPO_ROOT || path.resolve(__dirname, '..', '..')
  const chartPath = path.join(repoRoot, 'applications', 'hive-tenants', 'charts', 'hive-tenants')

  const {
    AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY,
    GUID,
    ROADSHOW,
    BASE_DOMAIN,
    PULL_SECRET,
    SSH_PUBLIC_KEY,
    // Optional values used by roadshow-install-config.yaml template
    INSTANCE_TYPE,
    ROOT_VOLUME_SIZE,
    AWS_DEFAULT_REGION,
    USER_EMAIL,
    USER_TEAM,
    USER_USAGE,
    USER_USAGE_DESCRIPTION,
    // Optional override
    installConfigOverride,
    dryRun,
  } = params

  const required = {
    AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY,
    GUID,
    ROADSHOW,
    BASE_DOMAIN,
    PULL_SECRET,
    SSH_PUBLIC_KEY,
  }
  const missing = Object.entries(required)
    .filter(([, v]) => v === undefined || v === null || String(v).trim() === '')
    .map(([k]) => k)
  if (missing.length) {
    const err = new Error(`Missing required fields: ${missing.join(', ')}`)
    err.statusCode = 400
    throw err
  }

  let pullSecretJson
  try {
    pullSecretJson = JSON.parse(PULL_SECRET)
  } catch (_e) {
    const err = new Error('PULL_SECRET must be valid JSON (paste the pull-secret JSON as-is)')
    err.statusCode = 400
    throw err
  }

  // Load the install-config template from the repo unless the UI provided an override.
  const installConfigPath = path.join(repoRoot, 'applications', 'hive-tenants', `${ROADSHOW}-install-config.yaml`)
  const installConfigTemplate = installConfigOverride && String(installConfigOverride).trim().length
    ? String(installConfigOverride)
    : await fs.readFile(installConfigPath, 'utf8')

  const vars = {
    AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY,
    GUID,
    ROADSHOW,
    BASE_DOMAIN,
    PULL_SECRET: JSON.stringify(pullSecretJson),
    SSH_PUBLIC_KEY,
    INSTANCE_TYPE,
    ROOT_VOLUME_SIZE,
    AWS_DEFAULT_REGION,
    USER_EMAIL,
    USER_TEAM,
    USER_USAGE,
    USER_USAGE_DESCRIPTION,
  }

  const renderedInstallConfig = envSubst(installConfigTemplate, vars)

  // Write rendered install-config to a temp file and use --set-file to avoid quoting/newline issues.
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'hive-ui-'))
  const tmpInstallConfigFile = path.join(tmpDir, 'install-config.yaml')
  await fs.writeFile(tmpInstallConfigFile, renderedInstallConfig, { encoding: 'utf8', mode: 0o600 })

  const helmArgs = [
    'template',
    'hive-tenants',
    chartPath,
    '--namespace=hive',
    '--set',
    `clusterPoolName=${ROADSHOW}`,
    '--set',
    `baseDomain=${BASE_DOMAIN}`,
    '--set-json',
    `globalPullSecret=${JSON.stringify(pullSecretJson)}`,
    '--set-file',
    `installConfig=${tmpInstallConfigFile}`,
    '--set',
    `guid=${GUID}`,
    '--set',
    `aws_access_key_id=${AWS_ACCESS_KEY_ID}`,
    '--set',
    `aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}`,
    '--set',
    `sshKey=${SSH_PUBLIC_KEY}`,
  ]

  const ocArgs = ['apply', '-f', '-']
  if (dryRun) {
    ocArgs.push('--dry-run=server')
  }

  return await new Promise((resolve, reject) => {
    const helm = spawn('helm', helmArgs, { stdio: ['ignore', 'pipe', 'pipe'] })
    const oc = spawn('oc', ocArgs, { stdio: ['pipe', 'pipe', 'pipe'] })

    helm.stdout.pipe(oc.stdin)

    let helmStderr = ''
    let ocStdout = ''
    let ocStderr = ''

    helm.stderr.on('data', (d) => (helmStderr += d.toString()))
    oc.stdout.on('data', (d) => (ocStdout += d.toString()))
    oc.stderr.on('data', (d) => (ocStderr += d.toString()))

    let helmExitCode = null
    let ocExitCode = null

    const maybeFinish = () => {
      if (helmExitCode === null || ocExitCode === null) return

      if (ocExitCode !== 0) {
        const err = new Error('oc apply failed')
        err.details = {
          helmExitCode,
          ocExitCode,
          helmStderr: truncate(helmStderr),
          ocStdout: truncate(ocStdout),
          ocStderr: truncate(ocStderr),
        }
        return reject(err)
      }

      if (helmExitCode !== 0) {
        const err = new Error('helm template failed')
        err.details = {
          helmExitCode,
          ocExitCode,
          helmStderr: truncate(helmStderr),
          ocStdout: truncate(ocStdout),
          ocStderr: truncate(ocStderr),
        }
        return reject(err)
      }

      return resolve({
        ok: true,
        message: 'configure_hive_tenants_roadshow ran OK',
        ocStdout: truncate(ocStdout),
        ocStderr: truncate(ocStderr),
      })
    }

    helm.on('error', (e) => reject(new Error(`Failed to start helm: ${e.message}`)))
    oc.on('error', (e) => reject(new Error(`Failed to start oc: ${e.message}`)))

    helm.on('close', (code) => {
      helmExitCode = code
      maybeFinish()
    })
    oc.on('close', (code) => {
      ocExitCode = code
      maybeFinish()
    })
  })
}

function requireAuth(req, res, next) {
  const token = process.env.ADMIN_TOKEN
  if (!token) return next()
  const h = req.headers.authorization || ''
  const ok = h.startsWith('Bearer ') && h.slice('Bearer '.length) === token
  if (!ok) return res.status(401).json({ ok: false, error: 'Unauthorized' })
  return next()
}

function isAuthorized(req) {
  const token = process.env.ADMIN_TOKEN
  if (!token) return false
  const h = req.headers.authorization || ''
  return h.startsWith('Bearer ') && h.slice('Bearer '.length) === token
}

// Allow API calls to work even when the app is served behind a sub-path (e.g. /hive-ui/...)
// or when the SPA is loaded on a deep URL and uses relative fetches.
app.get(/\/api\/defaults\/?$/, (req, res) => {
  const prefillSecrets = String(process.env.PREFILL_SECRETS || '').toLowerCase() === 'true'
  const includeSecrets = prefillSecrets && isAuthorized(req)

  const defaults = {
    GUID: process.env.GUID || '',
    ROADSHOW: process.env.ROADSHOW || 'roadshow',
    BASE_DOMAIN: process.env.BASE_DOMAIN || '',
    INSTANCE_TYPE: process.env.INSTANCE_TYPE || '',
    ROOT_VOLUME_SIZE: process.env.ROOT_VOLUME_SIZE || '',
    AWS_DEFAULT_REGION: process.env.AWS_DEFAULT_REGION || '',
    USER_EMAIL: process.env.USER_EMAIL || '',
    USER_TEAM: process.env.USER_TEAM || '',
    USER_USAGE: process.env.USER_USAGE || '',
    USER_USAGE_DESCRIPTION: process.env.USER_USAGE_DESCRIPTION || '',
  }

  if (includeSecrets) {
    defaults.AWS_ACCESS_KEY_ID = process.env.AWS_ACCESS_KEY_ID || ''
    defaults.AWS_SECRET_ACCESS_KEY = process.env.AWS_SECRET_ACCESS_KEY || ''
    defaults.PULL_SECRET = process.env.PULL_SECRET || ''
    defaults.SSH_PUBLIC_KEY = process.env.SSH_PUBLIC_KEY || ''
  }

  return res.json({
    ok: true,
    includeSecrets,
    defaults,
    note: includeSecrets
      ? undefined
      : (prefillSecrets
          ? 'Secrets are enabled but require ADMIN_TOKEN auth to be returned'
          : 'Secrets are not enabled (set PREFILL_SECRETS=true and ADMIN_TOKEN to allow)'),
  })
})

app.post(/\/api\/configure-hive-tenants-roadshow\/?$/, requireAuth, async (req, res) => {
  try {
    // Never log request body (contains secrets).
    const result = await configureHiveTenantsRoadshow(req.body || {})
    return res.json(result)
  } catch (e) {
    const status = e.statusCode || 500
    return res.status(status).json({
      ok: false,
      error: e.message || 'Unknown error',
      details: e.details,
    })
  }
})

// Ensure API 404s are JSON (otherwise Express sends an HTML error page, which breaks SPA fetch-json)
app.use(/\/api(\/|$)/, (_req, res) => {
  res.status(404).json({ ok: false, error: 'API route not found' })
})

// Catch-all route for SPA-style navigation (Express v5-safe wildcard)
app.get(/.*/, function (req, res) {
  res.sendFile(path.join(__dirname, 'index.html'))
})

app.listen(port, () => {
  console.log(`hive-ui listening on :${port}`)
})
