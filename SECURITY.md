# Security Policy

## Reporting Security Vulnerabilities

If you discover a security vulnerability, please email the maintainer directly rather than opening a public issue.

## Security Best Practices

### Configuration Files

1. **NEVER commit actual configuration values**
   - Use `.example` files for templates
   - Keep actual `config.env` and `nodes.conf` in `.gitignore`
   - Store sensitive values in environment variables

2. **IP Addresses and Usernames**
   - Do not commit real IP addresses
   - Do not commit real usernames
   - Use placeholders like `<CONTROL_PLANE_IP>` in examples

3. **Secrets Management**
   - Never store tokens, keys, or passwords in Git
   - Use `.env.local` for local secrets (git-ignored)
   - Consider using macOS Keychain for credentials

### File Permissions

```bash
# Secure your local configuration
chmod 600 configs/base/config.env
chmod 600 configs/base/nodes.conf
chmod 600 ~/.ssh/id_rsa
```

### Pre-commit Checks

Before committing, always check for sensitive data:

```bash
# Check for IP addresses
git diff --cached | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'

# Check for potential secrets
git diff --cached | grep -iE 'password|token|secret|key'
```

## Security Features

- All scripts validate input and use proper quoting
- Comprehensive logging for audit trails
- Automatic rollback on failures
- TLS certificates for cluster communication
- RBAC policies for access control

## Recommended Setup

1. Copy example files:
   ```bash
   cp configs/base/config.env.example configs/base/config.env
   cp configs/base/nodes.conf.example configs/base/nodes.conf
   ```

2. Edit with your values (these files are git-ignored)

3. Set restrictive permissions:
   ```bash
   chmod 600 configs/base/*.env
   chmod 600 configs/base/*.conf
   ```

4. Use environment variables for extra sensitive data:
   ```bash
   export CLUSTER_TOKEN="your-secret-token"
   ```