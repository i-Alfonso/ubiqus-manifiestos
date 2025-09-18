#!/bin/bash

# K3s Initialization Script - Optimized Version
# Uses FlowLB for SSL instead of cert-manager
# Reduces costs and complexity

set -e

DOMAIN_NAME="${domain_name}"
ENVIRONMENT="${environment}"

echo "🚀 Starting K3s initialization for $${ENVIRONMENT} environment..."
echo "📍 Domain: $${DOMAIN_NAME}"

# Update system
echo "📦 Updating system packages..."
apt-get update
apt-get upgrade -y

# Install required packages
echo "🔧 Installing required packages..."
apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    jq \
    htop \
    docker.io \
    docker-compose

# Configure Docker
echo "🐳 Configuring Docker..."
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Create directories for persistent storage
echo "📁 Creating storage directories..."
mkdir -p /mnt/k3s-data/{dev,staging,prod}/{mysql,drupal-files,flowlb-certs,flowlb-vhost,flowlb-html}
chown -R ubuntu:ubuntu /mnt/k3s-data

# Install K3s without Traefik (FlowLB will handle ingress)
echo "☸️ Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb" sh -

# Wait for K3s to be ready
echo "⏳ Waiting for K3s to be ready..."
sleep 30

# Configure kubectl for ubuntu user - FIXED
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config

# Set KUBECONFIG environment variable permanently
echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc

# Create namespaces for different environments
echo "🏷️ Creating namespaces..."
export KUBECONFIG=/home/ubuntu/.kube/config
kubectl create namespace ubiqus-dev || true
kubectl create namespace ubiqus-staging || true
kubectl create namespace ubiqus-prod || true

# Create local storage class
echo "💾 Creating local storage class..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

# Create persistent volumes for each environment
echo "📦 Creating persistent volumes..."
for env in dev staging prod; do
  # MySQL PV
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mysql-pv-$${env}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/k3s-data/$${env}/mysql
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $$(hostname)
EOF

  # Drupal files PV
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: drupal-files-pv-$${env}
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/k3s-data/$${env}/drupal-files
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $$(hostname)
EOF

  # FlowLB certs PV
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: flowlb-certs-pv-$${env}
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/k3s-data/$${env}/flowlb-certs
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $$(hostname)
EOF

  # FlowLB vhost PV
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: flowlb-vhost-pv-$${env}
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/k3s-data/$${env}/flowlb-vhost
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $$(hostname)
EOF

  # FlowLB html PV
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: flowlb-html-pv-$${env}
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/k3s-data/$${env}/flowlb-html
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $$(hostname)
EOF
done

# Install kubectl for easier management
echo "🔧 Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Create useful aliases and scripts
echo "📝 Creating management scripts..."
cat <<'EOF' > /home/ubuntu/k3s-status.sh
#!/bin/bash
export KUBECONFIG=/home/ubuntu/.kube/config
echo "=== K3s Cluster Status ==="
kubectl get nodes
echo ""
echo "=== Namespaces ==="
kubectl get namespaces
echo ""
echo "=== All Pods ==="
kubectl get pods -A
echo ""
echo "=== Persistent Volumes ==="
kubectl get pv
echo ""
echo "=== Services ==="
kubectl get svc -A
EOF

cat <<'EOF' > /home/ubuntu/k3s-logs.sh
#!/bin/bash
export KUBECONFIG=/home/ubuntu/.kube/config
ENV=$${1:-prod}
COMPONENT=$${2:-all}

if [ "$$COMPONENT" = "all" ]; then
    echo "=== All pods in ubiqus-$$ENV ==="
    kubectl get pods -n ubiqus-$$ENV
    echo ""
    echo "=== FlowLB logs ==="
    kubectl logs -n ubiqus-$$ENV -l app=flowlb --tail=50 2>/dev/null || echo "No FlowLB pods found"
    echo ""
    echo "=== Drupal logs ==="
    kubectl logs -n ubiqus-$$ENV -l app=drupal --tail=50 2>/dev/null || echo "No Drupal pods found"
else
    kubectl logs -n ubiqus-$$ENV -l app=$$COMPONENT --tail=100 -f
fi
EOF

cat <<'EOF' > /home/ubuntu/k3s-deploy.sh
#!/bin/bash
export KUBECONFIG=/home/ubuntu/.kube/config
ENV=$${1:-dev}
echo "Deploying to $$ENV environment..."
kubectl apply -k /home/ubuntu/k8s-manifests/overlays/$$ENV
echo "Waiting for deployments to be ready..."
kubectl rollout status deployment/flowlb -n ubiqus-$$ENV --timeout=300s || echo "FlowLB deployment timeout"
kubectl rollout status deployment/mysql -n ubiqus-$$ENV --timeout=300s || echo "MySQL deployment timeout"
kubectl rollout status deployment/drupal -n ubiqus-$$ENV --timeout=300s || echo "Drupal deployment timeout"
kubectl rollout status deployment/frontend -n ubiqus-$$ENV --timeout=300s || echo "Frontend deployment timeout"
echo "Deployment completed!"
EOF

chmod +x /home/ubuntu/*.sh
chown ubuntu:ubuntu /home/ubuntu/*.sh

# Create Docker network for FlowLB compatibility
echo "🌐 Creating Docker network for FlowLB..."
docker network create service-tier || true

# Set up environment variables
echo "🔧 Setting up environment..."
cat <<EOF >> /home/ubuntu/.bashrc
export KUBECONFIG=/home/ubuntu/.kube/config
alias k=kubectl
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kaf='kubectl apply -f'
alias kdel='kubectl delete'
EOF

# Create initial FlowLB configuration
echo "🔧 Creating FlowLB configuration..."
mkdir -p /mnt/k3s-data/prod/flowlb-vhost
cat <<EOF > /mnt/k3s-data/prod/flowlb-vhost/default.conf
# FlowLB configuration will be managed by K8s
# This is a placeholder
EOF

echo "✅ K3s initialization completed!"
echo ""
echo "📋 Summary:"
echo "- K3s cluster: Ready"
echo "- Namespaces: ubiqus-dev, ubiqus-staging, ubiqus-prod"
echo "- Storage: Local persistent volumes created"
echo "- FlowLB: Ready to deploy (replaces cert-manager)"
echo "- Management scripts: /home/ubuntu/*.sh"
echo "- kubectl: Configured for ubuntu user"
echo ""
echo "🚀 Next steps:"
echo "1. Deploy your K8s manifests"
echo "2. Configure FlowLB for SSL termination"
echo "3. Test each environment"
echo ""
echo "💡 Useful commands:"
echo "- /home/ubuntu/k3s-status.sh"
echo "- /home/ubuntu/k3s-logs.sh [env] [component]"
echo "- /home/ubuntu/k3s-deploy.sh [env]"
