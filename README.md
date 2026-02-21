# Hello World App on k3s with ArgoCD

A simple Node.js hello world application deployed on a k3s Kubernetes cluster, managed by ArgoCD for GitOps-based continuous deployment.

## Features

- Simple Node.js HTTP server
- Containerized with Docker
- Deployed on k3s (lightweight Kubernetes)
- GitOps deployment with ArgoCD
- Automated with Makefile
- All-in-one setup command

## Prerequisites

- Docker
- k3d (k3s in Docker)
- kubectl

### Install k3d:

```bash
# macOS
brew install k3d

# Linux
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

## Security: SSH Key Setup

**IMPORTANT**: ArgoCD uses SSH to access the Git repository. Your SSH keys are stored **ONLY** in your local cluster and are **NEVER committed to Git**.

### First-Time Setup

1. **Generate an SSH key** (if you don't have one):
   ```bash
   ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
   # Press Enter to accept default location (~/.ssh/id_rsa)
   ```

2. **Add your SSH public key to GitHub**:
   ```bash
   # Copy your public key
   cat ~/.ssh/id_rsa.pub
   
   # Then add it to: https://github.com/settings/keys
   ```

3. **The Makefile will automatically add your SSH key to ArgoCD** during setup

### How It Works

- SSH private key is stored as a Kubernetes secret in your cluster
- Secret is created locally by each user
- Secret is **NOT** stored in Git
- `.gitignore` prevents accidental commits of SSH keys
- Other users must add their own SSH keys

### For Team Members

When someone else clones this repo, they need to:
1. Ensure their SSH public key is on GitHub
2. Run `make setup` (which includes `make argocd-add-ssh-key`)
3. Their own SSH key will be added to their cluster (not yours!)

## Quick Start

### One-Command Setup with ArgoCD

**Prerequisites**: Make sure you have an SSH key and it's added to GitHub (see Security section above).

To create the cluster, install ArgoCD, build the image, and deploy in one command:

```bash
make setup
```

This will:
1. Create a k3s cluster
2. Install ArgoCD
3. Add your SSH key to ArgoCD (securely, only in your cluster)
4. Build the Docker image
5. Deploy the app using ArgoCD

### Access Your App

```bash
make port-forward
# App available at http://localhost:3000
```

Or access directly at: http://localhost:30000

### Access ArgoCD UI

```bash
# Get the admin password
make argocd-password

# Port forward to ArgoCD UI
make argocd-ui
# Then open https://localhost:8080
# Username: admin
# Password: (from argocd-password command)
```

## Available Make Commands

### Cluster Management
- `make create-cluster` - Create k3s cluster
- `make delete-cluster` - Delete the cluster
- `make clean` - Delete cluster and remove Docker image

### ArgoCD
- `make install-argocd` - Install ArgoCD in cluster
- `make argocd-password` - Get ArgoCD admin password
- `make argocd-ui` - Port forward to ArgoCD UI (localhost:8080)
- `make argocd-deploy` - Deploy app using ArgoCD
- `make argocd-status` - Check ArgoCD application status

### Application
- `make build` - Build Docker image
- `make deploy` - Deploy app directly with kubectl (not recommended)
- `make port-forward` - Port forward to access app locally
- `make status` - Check cluster and app status
- `make logs` - View app logs

### Full Setup
- `make setup` - Complete setup (cluster + ArgoCD + app)
- `make help` - Show all available commands

## Manual Steps

If you prefer to do things step by step:

1. **Create cluster:**
   ```bash
   make create-cluster
   ```

2. **Install ArgoCD:**
   ```bash
   make install-argocd
   ```

3. **Add your SSH key to ArgoCD:**
   ```bash
   make argocd-add-ssh-key
   # Or specify a different key:
   # make argocd-add-ssh-key SSH_KEY_PATH=~/.ssh/id_ed25519
   ```

4. **Build Docker image:**
   ```bash
   make build
   ```

5. **Deploy with ArgoCD:**
   ```bash
   make argocd-deploy
   ```

5. **Access the app:**
   ```bash
   make port-forward
   # Open http://localhost:3000
   ```

6. **Access ArgoCD UI (optional):**
   ```bash
   make argocd-ui
   # Open https://localhost:8080
   ```

## How to Access

After deployment, you have two options:

1. **Port Forward (Recommended for local dev):**
   ```bash
   make port-forward
   # Then access at http://localhost:3000
   ```

2. **NodePort Service:**
   - Direct access at `http://localhost:30000`
   - Available once the cluster is running

## Project Structure

```
.
|-- app.js              # Node.js application
|-- package.json        # Node dependencies
|-- Dockerfile          # Container image definition
|-- Makefile            # Build and deployment automation
|-- k8s/
|   |-- deployment.yaml # Kubernetes deployment
|   `-- service.yaml    # Kubernetes service
|-- argocd/
|   `-- application.yaml # ArgoCD application manifest
`-- README.md          # This file
```

## How ArgoCD Works

ArgoCD continuously monitors the Git repository and automatically syncs any changes to the cluster. This enables:

- **GitOps Workflow**: All configuration is stored in Git
- **Automated Deployment**: Push to main branch, ArgoCD deploys automatically
- **Self-Healing**: If manual changes are made, ArgoCD reverts them
- **Version Control**: Full history of all deployments
- **Secure SSH Access**: Uses SSH keys (stored only in your cluster, not in Git)

The ArgoCD application manifest ([argocd/application.yaml](argocd/application.yaml)) is configured to:
- Monitor the `main` branch via SSH (`git@github.com:sarvap37/sample-app.git`)
- Sync from the `k8s/` directory
- Auto-sync and self-heal
- Deploy to the `default` namespace

### SSH Security Model

- SSH private keys are stored as Kubernetes secrets in the `argocd` namespace
- Keys are never committed to Git (protected by `.gitignore`)
- Each user adds their own SSH key locally
- ArgoCD uses the secret to authenticate with GitHub

## Cleanup

To remove everything:

```bash
make clean
```

## Troubleshooting

### Cluster not starting
```bash
k3d cluster list
k3d cluster delete hello-world-cluster
make create-cluster
```

### Image not found in cluster
```bash
make load-image
```

### App not responding
Check pod status:
```bash
make status
make logs
```

### ArgoCD application not syncing
Check ArgoCD status:
```bash
make argocd-status
kubectl get applications -n argocd
kubectl describe application hello-world-app -n argocd
```

### Cannot access ArgoCD UI
Check if ArgoCD is running:
```bash
kubectl get pods -n argocd
# Wait for all pods to be Running
make argocd-ui
```

### Forgot ArgoCD password
```bash
make argocd-password
```

## Making Changes

To update your application:

1. Modify your code (e.g., [app.js](app.js))
2. Commit and push to GitHub:
   ```bash
   git add .
   git commit -m "Your changes"
   git push
   ```
3. Rebuild and reload image:
   ```bash
   make build
   make load-image
   ```
4. ArgoCD will automatically sync the changes, or manually refresh in the UI

> **Note**: For local development, you need to rebuild and reload the Docker image since we're using a local k3s cluster, not pulling from a remote registry.
