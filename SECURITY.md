# Security Policy

## SSH Key Management

This repository uses SSH keys for ArgoCD to authenticate with GitHub. Here's how we ensure security:

### What is secure

1. **SSH keys are never committed to Git**
   - All SSH key patterns are in `.gitignore`
   - Keys are stored only as Kubernetes secrets in your local cluster
   - Each user manages their own private keys

2. **Local-only storage**
   - SSH keys exist only in your local k3s cluster
   - They are stored as Kubernetes secrets in the `argocd` namespace
   - Secrets are not exported or shared

3. **User-specific keys**
   - Each developer uses their own SSH key
   - Running `make argocd-add-ssh-key` adds YOUR key, not a shared key
   - Team members cannot access each other's keys

### What is not in this repository

- No SSH private keys
- No SSH public keys
- No credentials of any kind
- No secrets or tokens

### Best Practices

1. **Never commit SSH keys**
   ```bash
   # The .gitignore already protects you from common mistakes:
   *.pem
   *.key
   id_rsa*
   id_ed25519*
   ```

2. **Use SSH agent (optional)**
   ```bash
   # Start SSH agent
   eval "$(ssh-agent -s)"
   
   # Add your key
   ssh-add ~/.ssh/id_rsa
   ```

3. **Use different keys for different purposes**
   - Consider using a dedicated SSH key for this project
   - Generate with: `ssh-keygen -t ed25519 -C "project-name"`

4. **Rotate keys periodically**
   ```bash
   # Remove old key from cluster
   kubectl delete secret github-ssh-key -n argocd
   
   # Add new key
   make argocd-add-ssh-key SSH_KEY_PATH=~/.ssh/new_key
   ```

### For New Team Members

When you clone this repository:

1. **Verify you have an SSH key**:
   ```bash
   ls -la ~/.ssh/
   # Look for id_rsa/id_rsa.pub or id_ed25519/id_ed25519.pub
   ```

2. **If you don't have a key, generate one**:
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   ```

3. **Add your PUBLIC key to GitHub**:
   - Copy your public key: `cat ~/.ssh/id_ed25519.pub`
   - Add it at: https://github.com/settings/keys

4. **Run setup** (it will automatically add your key to ArgoCD):
   ```bash
   make setup
   ```

### How to Verify Security

Check that no secrets are in Git:
```bash
# Search for common secret patterns (should return nothing sensitive)
git log --all --full-history -- "*.pem" "*.key" "*id_rsa*"

# Check .gitignore is protecting you
cat .gitignore | grep -E "pem|key|id_rsa"
```

View secrets in your cluster (they're local only):
```bash
# List secrets in argocd namespace
kubectl get secrets -n argocd

# View the secret (base64 encoded, only visible in YOUR cluster)
kubectl get secret github-ssh-key -n argocd -o yaml
```

### Technical Details

The `make argocd-add-ssh-key` command:

1. Reads your SSH private key from `~/.ssh/id_rsa` (or specified path)
2. Fetches GitHub's SSH host key using `ssh-keyscan`
3. Creates a Kubernetes secret in your local cluster only
4. Labels it for ArgoCD to use
5. Never sends the key anywhere except your local cluster

The secret is created with:
```bash
kubectl create secret generic github-ssh-key \
  -n argocd \
  --from-file=sshPrivateKey=$SSH_KEY_PATH \
  --from-file=known_hosts=/tmp/github_known_hosts
```

### What to Do If a Key is Exposed

If you accidentally commit an SSH key:

1. **Immediately revoke it on GitHub**:
   - Go to: https://github.com/settings/keys
   - Delete the exposed key

2. **Remove it from Git history**:
   ```bash
   # Use git filter-branch or BFG Repo-Cleaner
   # This is complex - contact your team lead
   ```

3. **Generate a new key**:
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   ```

4. **Update your cluster**:
   ```bash
   kubectl delete secret github-ssh-key -n argocd
   make argocd-add-ssh-key
   ```

### Reporting Security Issues

If you discover a security vulnerability, please email: [your-email@example.com]

Do NOT create a public GitHub issue for security vulnerabilities.

## Additional Resources

- [GitHub SSH Key Guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
- [ArgoCD Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [Kubernetes Secrets Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/)
