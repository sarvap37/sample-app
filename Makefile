.PHONY: help create-cluster delete-cluster build deploy port-forward clean install-argocd argocd-deploy argocd-status argocd-ui argocd-password argocd-add-ssh-key check-ssh-key scenario-crash scenario-oom scenario-fix

CLUSTER_NAME = hello-world-cluster
APP_NAME = hello-world-app
DOCKER_IMAGE = $(APP_NAME):latest
KUBE_NAMESPACE = default
ARGOCD_NAMESPACE = argocd
SSH_KEY_PATH = $(HOME)/.ssh/id_rsa

help:
	@echo "Available targets:"
	@echo ""
	@echo "Cluster Management:"
	@echo "  make create-cluster   - Create k3s cluster"
	@echo "  make delete-cluster   - Delete k3s cluster"
	@echo ""
	@echo "ArgoCD Installation:"
	@echo "  make install-argocd   - Install ArgoCD in cluster"
	@echo "  make check-ssh-key    - Validate SSH key path before setup"
	@echo "  make argocd-add-ssh-key - Add your SSH key to ArgoCD (required for Git access)"
	@echo "  make argocd-password  - Get ArgoCD admin password"
	@echo "  make argocd-ui        - Port forward to ArgoCD UI (localhost:8080)"
	@echo ""
	@echo "Application Deployment:"
	@echo "  make build            - Build Docker image"
	@echo "  make deploy           - Deploy app using kubectl (direct)"
	@echo "  make argocd-deploy    - Deploy app using ArgoCD"
	@echo ""
	@echo "Monitoring & Access:"
	@echo "  make port-forward     - Port forward to access app locally"
	@echo "  make status           - Check cluster status"
	@echo "  make argocd-status    - Check ArgoCD application status"
	@echo "  make logs             - View app logs"
	@echo ""
	@echo "Failure Scenarios (for testing):"
	@echo "  make scenario-crash   - Deploy app that crashes after 5 requests (CrashLoopBackOff)"
	@echo "  make scenario-oom     - Deploy app that runs out of memory (OOMKilled)"
	@echo "  make scenario-fix     - Fix by redeploying the normal app"
	@echo ""
	@echo "Full Setup:"
	@echo "  make setup            - Create cluster, build, install ArgoCD & deploy"
	@echo "  make clean            - Clean up all resources"

# Create k3s cluster
create-cluster:
	@echo "Creating k3s cluster: $(CLUSTER_NAME)"
	k3d cluster create $(CLUSTER_NAME) --agents 1 -p "8080:80@loadbalancer" -p "8443:443@loadbalancer" || true
	@echo "Cluster created successfully!"

# Install ArgoCD
install-argocd:
	@echo "Installing ArgoCD..."
	kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(ARGOCD_NAMESPACE) -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "Waiting for ArgoCD to be ready..."
	kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n $(ARGOCD_NAMESPACE)
	@echo "ArgoCD installed successfully!"
	@echo ""
	@echo "IMPORTANT: Add your SSH key to ArgoCD: make argocd-add-ssh-key"
	@echo "To access ArgoCD UI, run: make argocd-ui"
	@echo "To get admin password, run: make argocd-password"

# Validate SSH key path
check-ssh-key:
	@KEY_PATH=$$(eval echo "$(SSH_KEY_PATH)"); \
	if [ ! -f "$$KEY_PATH" ]; then \
		echo "Error: SSH key not found at $$KEY_PATH"; \
		echo "Please generate an SSH key first:"; \
		echo "  ssh-keygen -t ed25519 -C 'your_email@example.com'"; \
		echo "Or specify a different key path:"; \
		echo "  make argocd-add-ssh-key SSH_KEY_PATH=\$$HOME/.ssh/id_ed25519"; \
		exit 1; \
	fi; \
	echo "SSH key found at $$KEY_PATH"

# Add SSH key to ArgoCD (secure - not stored in Git)
argocd-add-ssh-key:
	@echo "Adding SSH key to ArgoCD..."
	@KEY_PATH=$$(eval echo "$(SSH_KEY_PATH)"); \
	if [ ! -f "$$KEY_PATH" ]; then \
		echo "Error: SSH key not found at $$KEY_PATH"; \
		echo "Please generate an SSH key first:"; \
		echo "  ssh-keygen -t ed25519 -C 'your_email@example.com'"; \
		echo "Or specify a different key path:"; \
		echo "  make argocd-add-ssh-key SSH_KEY_PATH=\$$HOME/.ssh/id_ed25519"; \
		exit 1; \
	fi; \
	echo "Using SSH key: $$KEY_PATH"; \
	ssh-keyscan github.com > /tmp/github_known_hosts 2>/dev/null; \
	kubectl create secret generic github-ssh-key \
		-n $(ARGOCD_NAMESPACE) \
		--from-literal=type=git \
		--from-literal=url=git@github.com:sarvap37/sample-app.git \
		--from-file=sshPrivateKey=$$KEY_PATH \
		--from-file=known_hosts=/tmp/github_known_hosts \
		--dry-run=client -o yaml | kubectl apply -f -; \
	kubectl label secret github-ssh-key -n $(ARGOCD_NAMESPACE) argocd.argoproj.io/secret-type=repository --overwrite; \
	rm -f /tmp/github_known_hosts; \
	echo "SSH key added successfully!"; \
	echo ""; \
	echo "SECURITY NOTE:"; \
	echo "  - This SSH key is stored ONLY in your local cluster"; \
	echo "  - It is NOT committed to Git"; \
	echo "  - Other users must add their own SSH keys using this command"; \
	echo "  - Make sure your SSH public key is added to GitHub:"; \
	echo "    https://github.com/settings/keys"

# Get ArgoCD admin password
argocd-password:
	@echo "ArgoCD Admin Password:"
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
	@echo ""

# Port forward to ArgoCD UI
argocd-ui:
	@echo "Port forwarding to ArgoCD UI..."
	@echo "ArgoCD UI will be available at: https://localhost:8080"
	@echo "Username: admin"
	@echo "Password: Run 'make argocd-password' to get the password"
	@echo ""
	kubectl port-forward svc/argocd-server -n $(ARGOCD_NAMESPACE) 8080:443

# Build Docker image
build:
	@echo "Building Docker image: $(DOCKER_IMAGE)"
	docker build -t $(DOCKER_IMAGE) .
	@echo "Image built successfully!"

# Load image into k3s cluster (for local images)
load-image: build
	@echo "Loading image into k3s cluster"
	k3d image import $(DOCKER_IMAGE) -c $(CLUSTER_NAME)

# Deploy to cluster
deploy: load-image
	@echo "Deploying app to cluster"
	kubectl apply -f k8s/deployment.yaml
	kubectl apply -f k8s/service.yaml
	@echo "Waiting for deployment to be ready..."
	kubectl rollout status deployment/$(APP_NAME) -n $(KUBE_NAMESPACE) --timeout=120s
	@echo "Deployment successful!"

# Deploy using ArgoCD
argocd-deploy: load-image
	@echo "Deploying app using ArgoCD..."
	kubectl apply -f argocd/application.yaml
	@echo "ArgoCD application created!"
	@echo "Waiting for application to sync..."
	@sleep 5
	@echo ""
	@echo "Application deployed! Check status with: make argocd-status"
	@echo "Or view in ArgoCD UI: make argocd-ui"

# Check ArgoCD application status
argocd-status:
	@echo "ArgoCD Application Status:"
	@kubectl get application -n $(ARGOCD_NAMESPACE)
	@echo ""
	@echo "Application Details:"
	@kubectl get application $(APP_NAME) -n $(ARGOCD_NAMESPACE) -o yaml | grep -A 10 "status:" || echo "Application not found"

# Port forward to access app locally
port-forward:
	@echo "Port forwarding to $(APP_NAME)..."
	@echo "App will be available at http://localhost:3000"
	kubectl port-forward svc/$(APP_NAME) 3000:3000 -n $(KUBE_NAMESPACE)

# Full setup: create cluster, build, and deploy
setup: check-ssh-key
	@$(MAKE) create-cluster
	@$(MAKE) install-argocd
	@$(MAKE) argocd-add-ssh-key
	@$(MAKE) build
	@$(MAKE) argocd-deploy
	@echo ""
	@echo "========================================="
	@echo "Setup complete! Your app is deployed via ArgoCD."
	@echo "========================================="
	@echo ""
	@echo "To access the app:"
	@echo "  make port-forward"
	@echo "  Or visit: http://localhost:30000"
	@echo ""
	@echo "To access ArgoCD UI:"
	@echo "  make argocd-ui"
	@echo "  Then visit: https://localhost:8080"
	@echo ""
	@echo "Get ArgoCD password:"
	@echo "  make argocd-password"
	@echo ""

# Delete cluster
delete-cluster:
	@echo "Deleting k3s cluster: $(CLUSTER_NAME)"
	k3d cluster delete $(CLUSTER_NAME)
	@echo "Cluster deleted!"

# Clean up
clean: delete-cluster
	@echo "Removing Docker image: $(DOCKER_IMAGE)"
	docker rmi -f $(DOCKER_IMAGE) 2>/dev/null || true
	@echo "Cleanup complete!"

# Check cluster status
status:
	@echo "Cluster nodes:"
	kubectl get nodes
	@echo ""
	@echo "Deployments:"
	kubectl get deployments -n $(KUBE_NAMESPACE)
	@echo ""
	@echo "Services:"
	kubectl get services -n $(KUBE_NAMESPACE)
	@echo ""
	@echo "Pods:"
	kubectl get pods -n $(KUBE_NAMESPACE)
	@echo ""
	@echo "ArgoCD Applications:"
	@kubectl get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "ArgoCD not installed"

# View logs
logs:
	kubectl logs -f deployment/$(APP_NAME) -n $(KUBE_NAMESPACE)
# Failure Scenario: CrashLoopBackOff
scenario-crash: build load-image
	@echo "Deploying CrashLoopBackOff scenario via ArgoCD..."
	@echo "The app will crash after 5 requests"
	@echo ""
	@# Remove other apps
	@kubectl delete application hello-world-app -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@kubectl delete application hello-world-app-oom -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@sleep 2
	@# Deploy crash scenario via ArgoCD
	@kubectl apply -f argocd/application-crash.yaml
	@echo ""
	@echo "Crash scenario deployed via ArgoCD!"
	@echo ""
	@echo "Monitor in ArgoCD UI: make argocd-ui"
	@echo "Check pods: kubectl get pods -n $(KUBE_NAMESPACE) -w"
	@echo "View logs: kubectl logs -f -l scenario=crash -n $(KUBE_NAMESPACE)"
	@echo "To fix: make scenario-fix"

# Failure Scenario: OOMKilled
scenario-oom: build load-image
	@echo "Deploying OOMKilled scenario via ArgoCD..."
	@echo "The app will exceed memory limits and be killed"
	@echo ""
	@# Remove other apps
	@kubectl delete application hello-world-app -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@kubectl delete application hello-world-app-crash -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@sleep 2
	@# Deploy OOM scenario via ArgoCD
	@kubectl apply -f argocd/application-oom.yaml
	@echo ""
	@echo "OOM scenario deployed via ArgoCD!"
	@echo ""
	@echo "Monitor in ArgoCD UI: make argocd-ui"
	@echo "Check pods: kubectl get pods -n $(KUBE_NAMESPACE) -w"
	@echo "View events: kubectl describe pod -l scenario=oom -n $(KUBE_NAMESPACE)"
	@echo "To fix: make scenario-fix"

# Fix Failure Scenarios
scenario-fix: build load-image
	@echo "Fixing failure scenarios - switching back to normal app via ArgoCD..."
	@# Remove scenario apps
	@kubectl delete application hello-world-app-crash -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@kubectl delete application hello-world-app-oom -n $(ARGOCD_NAMESPACE) 2>/dev/null || true
	@sleep 2
	@# Deploy normal app via ArgoCD
	@kubectl apply -f argocd/application.yaml
	@echo ""
	@echo "Normal app redeployed via ArgoCD!"
	@echo ""
	@echo "Monitor in ArgoCD UI: make argocd-ui"
	@echo "Check status: make argocd-status"
	@echo "Access app: make port-forward"