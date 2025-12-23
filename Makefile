# Full-Stack Observability System - Makefile

.PHONY: help setup clean test build deploy

help: ## Show this help message
	@echo "Full-Stack Observability System"
	@echo ""
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

setup: ## Set up the development environment
	@echo "Setting up development environment..."
	# Install Python dependencies for sample app
	cd sample-app && pip install -r requirements.txt
	# Install Python dependencies for chatops bot
	cd chatops-bot && pip install -r requirements.txt

clean: ## Clean up temporary files and containers
	@echo "Cleaning up..."
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	find . -type f -name "*.pyo" -delete
	docker-compose -f docker/docker-compose.yml down -v

test: ## Run tests
	@echo "Running tests..."
	# Add test commands here
	@echo "No tests implemented yet"

build: ## Build Docker images
	@echo "Building Docker images..."
	docker-compose -f docker/docker-compose.yml build

deploy-local: ## Deploy locally using Docker Compose
	@echo "Deploying locally..."
	docker-compose -f docker/docker-compose.yml up -d

stop-local: ## Stop local deployment
	@echo "Stopping local deployment..."
	docker-compose -f docker/docker-compose.yml down

logs: ## Show logs from local deployment
	docker-compose -f docker/docker-compose.yml logs -f

terraform-init: ## Initialize Terraform
	cd terraform && terraform init

terraform-plan: ## Show Terraform plan
	cd terraform && terraform plan

terraform-apply: ## Apply Terraform configuration
	cd terraform && terraform apply

terraform-destroy: ## Destroy Terraform resources
	cd terraform && terraform destroy

k8s-deploy: ## Deploy to Kubernetes
	@echo "Deploying to Kubernetes..."
	kubectl apply -f kubernetes-configs/

k8s-delete: ## Delete from Kubernetes
	@echo "Deleting from Kubernetes..."
	kubectl delete -f kubernetes-configs/

cleanup: ## Run interactive cleanup script
	@echo "Running cleanup script..."
	./scripts/cleanup.sh

cleanup-local: ## Clean up local Docker resources only
	@echo "Cleaning up local Docker resources..."
	docker-compose -f docker/docker-compose.yml down -v --remove-orphans
	docker image prune -f
	docker volume prune -f

cleanup-aws: ## Clean up AWS resources (use with caution)
	@echo "Cleaning up AWS resources..."
	@echo "This will delete ECR repositories, S3 buckets, SNS topics, etc."
	@echo "Run ./scripts/cleanup.sh for interactive cleanup"

cleanup-full: ## Full cleanup including EKS cluster (DESTRUCTIVE)
	@echo "WARNING: This will delete the entire EKS cluster!"
	@echo "Run ./scripts/cleanup.sh and select option 4 for full cleanup"

validate: ## Run interactive validation script
	@echo "Running validation script..."
	./scripts/validate.sh

validate-local: ## Validate local Docker setup
	@echo "Validating local Docker setup..."
	./scripts/validate.sh < /dev/null || true

validate-k8s: ## Validate Kubernetes resources
	@echo "Validating Kubernetes resources..."
	@echo "2" | ./scripts/validate.sh

validate-aws: ## Validate AWS resources
	@echo "Validating AWS resources..."
	@echo "3" | ./scripts/validate.sh

lint: ## Lint Python code
	@echo "Linting Python code..."
	flake8 sample-app chatops-bot scripts --max-line-length=100

format: ## Format Python code
	@echo "Formatting Python code..."
	black sample-app chatops-bot scripts