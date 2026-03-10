# agenix-rekey-to-sops

SOPS output extension for [agenix-rekey](https://github.com/oddlama/agenix-rekey).

Enables automatic generation of SOPS-encrypted files from age-encrypted secrets for use with [nixidy](https://github.com/arnarg/nixidy), vals, and Kubernetes secret management.

## Features

- ✅ **Automatic SOPS generation** - Convert age-encrypted secrets to SOPS format
- ✅ **Secret grouping** - Organize secrets into logical SOPS YAML files
- ✅ **Multiple formats** - Support for `str`, `base64`, and `binary` outputs
- ✅ **Vals integration** - Generates `ref+sops://` URIs for vals templating
- ✅ **Generic design** - Works with nixidy, terranix, or any custom Nix config

## Quick Start

### 1. Add to your flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix-rekey.url = "github:sini/agenix-rekey";  # Fork with extraConfigurations support
    agenix-rekey-to-sops.url = "github:sini/agenix-rekey-to-sops";
    agenix-rekey-to-sops.inputs.agenix-rekey.follows = "agenix-rekey";
    nixidy.url = "github:arnarg/nixidy";
  };

  outputs = { self, nixpkgs, agenix-rekey-to-sops, nixidy, ... }:
  let
    pkgs = import nixpkgs { system = "x86_64-linux"; };
  in {
    # Define your nixidy configuration
    extraConfigurations.production = nixidy.lib.mkEnv {
      inherit pkgs;
      modules = [
        agenix-rekey-to-sops.nixidyModules.default
        {
          age = {
            sops = {
              configFile = ./.sops.yaml;
              outputDir = ./.secrets/prod;
            };

            rekey.masterIdentities = [ ./master-key.pub ];

            secrets = {
              database-password = {
                rekeyFile = ./secrets/db-pass.age;
                sopsOutput = {
                  file = "app-secrets";  # Groups into app-secrets.enc.yaml
                  key = "database-password";
                  format = "str";  # or "base64" or "binary"
                };
              };
            };
          };
        }
      ];
    };

    # Get agenix-rekey apps with sops-rekey included
    agenix-rekey = agenix-rekey-to-sops.configure {
      userFlake = self;
      inherit (self) extraConfigurations;
    };
  };
}
```

### 2. Create `.sops.yaml` configuration

```yaml
creation_rules:
  - path_regex: \.secrets/prod/.*\.enc\.yaml$
    age:
      - age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

### 3. Generate secrets

```bash
# Generate age-encrypted source secrets
agenix generate

# Convert to SOPS format
agenix sops-rekey

# Add to git
agenix sops-rekey -a
```

## Module Schema

The SOPS module extends agenix-rekey's secret schema with:

### `age.sops` Options

```nix
age.sops = {
  configFile = ./.sops.yaml;  # Path to SOPS config
  outputDir = ./.secrets;      # Where to generate SOPS files
};
```

### `age.secrets.<name>.sopsOutput` Options

```nix
age.secrets.my-secret = {
  rekeyFile = ./secrets/my-secret.age;  # Source age-encrypted file

  sopsOutput = {
    file = "app-secrets";  # SOPS filename (without extension)
    key = "my-key";        # YAML key within the file
    format = "str";        # "str" | "base64" | "binary"
  };
};
```

### Computed `sopsRef` Attribute

```nix
config.age.secrets.my-secret.sopsRef
# Returns: "ref+sops://.../.secrets/app-secrets.enc.yaml#my-key"
```

## Formats

### `str` - Plain Text (default)
For passwords, tokens, connection strings:

```nix
sopsOutput = {
  file = "credentials";
  key = "database-password";
  format = "str";
};
```

Generated YAML:
```yaml
database-password: my-secret-password
```

### `base64` - Base64 Encoded
For Kubernetes `Secret.data` fields (pre-encoded):

```nix
sopsOutput = {
  file = "tls";
  key = "cert.pem";
  format = "base64";
};
```

Generated YAML:
```yaml
cert.pem: LS0tLS1CRUdJTi...  # base64-encoded
```

### `binary` - Entire File
For large files or binary data:

```nix
sopsOutput = {
  file = "ca-bundle";
  format = "binary";
};
```

Generates `ca-bundle.enc` (entire file encrypted, no YAML)

## Using in Nixidy Manifests

### Simple String Secret

```nix
{
  kubernetes.resources.secrets.database = {
    type = "Opaque";
    stringData.password = config.age.secrets."database-password".sopsRef;
  };
}
```

### TLS Certificate (base64)

```nix
{
  kubernetes.resources.secrets.app-tls = {
    type = "kubernetes.io/tls";
    data = {
      "tls.crt" = config.age.secrets."tls-cert".sopsRef;
      "tls.key" = config.age.secrets."tls-key".sopsRef;
    };
  };
}
```

### Environment Variables

```nix
{
  kubernetes.resources.deployments.app = {
    spec.template.spec.containers = [{
      name = "app";
      env = [{
        name = "DB_PASSWORD";
        value = config.age.secrets."database-password".sopsRef;
      }];
    }];
  };
}
```

## Deployment Workflow

```bash
# 1. Generate SOPS files
cd your-project
agenix sops-rekey -a

# 2. Build Kubernetes manifests (nixidy)
nixidy build

# 3. Deploy with vals evaluation
helm template ./output | vals eval -f - | kubectl apply -f -
```

Vals will:
1. Parse the `ref+sops://` URIs
2. Decrypt using keys from `.sops.yaml`
3. Replace URIs with plaintext values
4. Apply to cluster

## Architecture

This extension is built in two layers:

### Layer 1: agenix-rekey Fork (Minimal)
- Adds `extraConfigurations` parameter (~30 lines)
- Generic support for custom configuration systems
- Potentially upstreamable

### Layer 2: This Flake (Extension)
- SOPS module with schema
- `sops-rekey` command
- Vals URI generation
- ~500 lines, clearly isolated

This separation means:
- ✅ Minimal fork maintenance burden
- ✅ Clear extension boundaries
- ✅ Easy to propose core changes upstream
- ✅ Works with any custom config system

## Requirements

**agenix-rekey fork:** https://github.com/sini/agenix-rekey

The fork adds generic `extraConfigurations` support which this extension uses.

**SOPS:** For encryption/decryption
```bash
nix-shell -p sops
```

**Vals (for deployment):** For evaluating `ref+sops://` URIs
```bash
nix-shell -p vals
```

## Examples

See [examples/nixidy](./examples/nixidy/) for a complete working example with:
- Nixidy environment configuration
- SOPS secret grouping
- YubiKey master identity
- Real `.sops.yaml` configuration

## Credits

Built on top of [agenix-rekey](https://github.com/oddlama/agenix-rekey) by oddlama.

Designed for use with:
- [nixidy](https://github.com/arnarg/nixidy) - Kubernetes with Nix
- [vals](https://github.com/helmfile/vals) - Secret templating

## License

MIT
