# Zeller ⚡

> High-performance, lightweight secret manager and process environment injector written in Zig. Inspired by [Teller](https://github.com/tellerops/teller).

`zeller` resolves secrets from multiple sources (local dotenv files, HashiCorp Vault, Doppler, external CLIs like 1Password `op` or AWS CLI) and injects them directly into child processes, shell environments, or outputs.

---

## Features

- **⚡ Sub-millisecond execution**: Injects secrets and launches child processes with virtually 0ms overhead.
- **🪶 Tiny binary**: Only ~840 KB (ReleaseSmall) compared to Go's 35-50 MB.
- **🧠 Extremely light memory footprint**: ~2.5 MB peak memory usage.
- **🔌 Multi-Provider Support**:
  - `dotenv`: Fast native parser for `.env` and environment files (quotes, multiline, escapes).
  - `hashicorp_vault`: Native HTTP REST client for HashiCorp Vault (KV v1 and KV v2).
  - `doppler`: Native HTTP REST client for Doppler Secrets API.
  - `exec`: Dynamic CLI bridge allowing any CLI tool (`op`, `aws`, `gcloud`, scripts) to supply secrets.
- **📁 Configuration Compatibility**: Supports `.teller.yml` YAML files, `.zeller.json` JSON files, or direct `.env` files.

---

## Installation & Build

Requires **Zig 0.13.0+**:

```bash
# Build optimized binary
zig build -Doptimize=ReleaseSmall

# Binary will be placed in zig-out/bin/zeller
./zig-out/bin/zeller --version
```

---

## Usage

### 1. Run a command with injected secrets
```bash
zeller run -- node index.js
zeller run -- cargo run
zeller run -c custom-config.yml -- ./my-binary
```

### 2. Export environment variables for current shell
```bash
eval $(zeller env)
```

### 3. Inspect resolved secrets
```bash
# Masked by default
zeller show

# Reveal actual values
zeller show --reveal
```

---

## Configuration Example

### `.teller.yml` (YAML)
```yaml
project: my-service

providers:
  dotenv:
    env:
      path: .env.production

  exec:
    path: printf 'DYNAMIC_GIT_SHA=1a2b3c4d\n'

  hashicorp_vault:
    env:
      path: secret/data/my-service
```

### `.zeller.json` (JSON)
```json
{
  "project": "my-service",
  "providers": [
    { "kind": "dotenv", "path": ".env" },
    { "kind": "exec", "path": "op read 'op://dev/database/password'" },
    { "kind": "vault", "path": "secret/data/my-service" },
    { "kind": "doppler", "path": "project=api&config=prd" }
  ]
}
```

---

## Testing

```bash
zig build test
```
