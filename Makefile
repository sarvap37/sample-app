.PHONY: help create-cluster delete-cluster build deploy port-forward clean

CLUSTER_NAME = hello-world-cluster
APP_NAME = hello-world-app
DOCKER_IMAGE = $(APP_NAME):latest
KUBE_NAMESPACE = default

help:
	@echo "Available targets:"
	@echo "  make create-cluster   - Create k3s cluster"
	@echo "  make build            - Build Docker image"
	@echo "  make deploy           - Deploy app to cluster"
	@echo "  make port-forward     - Port forward to access app locally"
	@echo "  make setup            - Create cluster, build, and deploy (one command)"
	@echo "  make delete-cluster   - Delete k3s cluster"
	@echo "  make clean            - Clean up all resources"

# Create k3s cluster
create-cluster:
	@echo "Creating k3s cluster: $(CLUSTER_NAME)"
	k3d cluster create $(CLUSTER_NAME) --agents 1 -p "8080:80@loadbalancer" -p "8443:443@loadbalancer" || true
	@echo "Cluster created successfully!"

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

# Port forward to access app locally
port-forward:
	@echo "Port forwarding to $(APP_NAME)..."
	@echo "App will be available at http://localhost:3000"
	kubectl port-forward svc/$(APP_NAME) 3000:3000 -n $(KUBE_NAMESPACE)

# Full setup: create cluster, build, and deploy
setup: create-cluster build deploy
	@echo ""
	@echo "Setup complete! Your app is deployed."
	@echo "To access the app, run: make port-forward"
	@echo "Or access it at: http://localhost:30000"

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

# View logs
logs:
	kubectl logs -f deployment/$(APP_NAME) -n $(KUBE_NAMESPACE)
