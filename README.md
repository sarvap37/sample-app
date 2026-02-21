# Hello World App on k3s

A simple Node.js hello world application deployed on a k3s Kubernetes cluster.

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

## Quick Start

### One-Command Setup

To create the cluster, build the image, and deploy in one command:

```bash
make setup
```

Then access your app:

```bash
make port-forward
```

Open http://localhost:3000 in your browser.

## Available Make Commands

- `make help` - Show all available commands
- `make create-cluster` - Create k3s cluster
- `make build` - Build Docker image
- `make deploy` - Deploy app to cluster
- `make setup` - Full setup (create cluster, build, deploy)
- `make port-forward` - Port forward to access app locally
- `make status` - Check cluster status
- `make logs` - View app logs
- `make delete-cluster` - Delete the cluster
- `make clean` - Delete cluster and remove Docker image

## Manual Steps

If you prefer to do things step by step:

1. **Create cluster:**
   ```bash
   make create-cluster
   ```

2. **Build Docker image:**
   ```bash
   make build
   ```

3. **Deploy to cluster:**
   ```bash
   make deploy
   ```

4. **Access the app:**
   ```bash
   make port-forward
   ```

5. Open http://localhost:3000 in your browser

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
├── app.js              # Node.js application
├── package.json        # Node dependencies
├── Dockerfile          # Container image definition
├── Makefile            # Build and deployment automation
├── k8s/
│   ├── deployment.yaml # Kubernetes deployment
│   └── service.yaml    # Kubernetes service
└── README.md          # This file
```

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
