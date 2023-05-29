#!/bin/bash

# Function to display messages in green color
print_green() {
    echo "$(tput setaf 2)$1$(tput sgr0)"
}

# Function to display messages in yellow color
print_yellow() {
    echo "$(tput setaf 3)$1$(tput sgr0)"
}

# Function to display messages in red color
print_red() {
    echo "$(tput setaf 1)$1$(tput sgr0)"
}

# Function to check if Helm is installed
check_helm_installed() {
    if ! [ -x "$(command -v helm)" ]; then
        print_red "Helm is not installed. Please install Helm first."
        exit 1
    fi
}

# Function to check if a Kubernetes cluster is reachable
check_kubernetes_cluster() {
    if ! kubectl cluster-info > /dev/null 2>&1; then
        print_red "Kubernetes cluster is not reachable. Please ensure you have a working cluster."
        exit 1
    fi
}

# Function to check if a kubectl context is set
check_kubectl_context() {
    local current_context
    
    current_context=$(kubectl config current-context)
    
    if [ -z "$current_context" ]; then
        print_yellow "No kubectl context is set."
        read -rp "Please set the desired kubectl context and press Enter to continue: " _unused
    else
        print_yellow "Current kubectl context: $current_context"
        read -rp "Is this the correct cluster you want to proceed with? (y/N): " confirm
        
        if [[ "$confirm" != [Yy] && -z "$confirm" ]]; then
            print_red "Aborting installation."
            exit 1
        fi
    fi
}

# Function to check if the ArgoCD CRDs are installed
check_argocd_crds_installed() {
    if kubectl get crd | grep -q 'argoproj.io'; then
        print_yellow "At least one ArgoCD CRD is already installed."
        return 0
    fi
    
    return 1
}

check_istio_crds_installed() {
    if kubectl get crd | grep -q 'istio.io'; then
        print_yellow "At least one Istio CRD is already installed."
        return 0
    fi
    
    return 1
}

# Function to check if Helm chart is already installed
check_chart_installed() {
    local chart_name=$1
    local chart_namespace=$2
    
    if helm list -n "$chart_namespace" | grep -q "$chart_name"; then
        print_yellow "The '$chart_name' chart is already installed in the '$chart_namespace' namespace."
        return 0
    fi
    
    return 1
}

# Function to install a Helm chart
install_helm_chart() {
    local chart_repo=$1
    local chart_name=$2
    local chart_namespace=$3
    local chart_version=$4
    local tenant_name=$5
    local cluster_token=$6
    
    print_green "Installing '$chart_name' chart in the '$chart_namespace' namespace..."
    
    if [ "$chart_name" == "tfy-agent" ]; then
        helm install "$chart_name" -n "$chart_namespace" --version "$chart_version" \
        --set config.tenantName="$tenant_name" \
        --set config.controlPlaneURL="https://$tenant_name.truefoundry.cloud" \
        --set config.clusterToken="$cluster_token" \
        truefoundry/"$chart_name" --create-namespace
    else
        helm install "$chart_name" -n "$chart_namespace" --version "$chart_version" "$chart_repo"/"$chart_name" --create-namespace
    fi
    
    print_green "The '$chart_name' chart has been successfully installed."
}


install_argocd_helm_chart() {
    helm install argocd argo/argo-cd --version 5.16.13 \
    --namespace argocd --create-namespace --wait \
    --set applicationSet.enabled=false \
    --set notifications.enabled=false \
    --set dex.enabled=false \
    --set server.extraArgs[0]="--insecure" \
    --set server.extraArgs[1]='--application-namespaces="*"' \
    --set controller.extraArgs[0]='--application-namespaces="*"'
}

get_cluster_ip() {
    local cluster_type=$1
    local cluster_name=$2
    local endpoint=''

    if [ "$cluster_type" == "aws-eks" ]; then
        endpont=$(aws eks describe-cluster --name $cluster_name --query "cluster.endpoint")
    else if [ "$cluster_type" == "gcp-gke" ]; then
        endpoint=$(gcloud container clusters describe $cluster_name --format="value(endpoint)")
    else if [ "$cluster_type" == "azure-aks" ]; then
        endpoint=$(az aks show --name $cluster_name --query 'fqdn')

    return $endpoint
}

install_istio() {
    local tenant_name=$1
    local cluster_token=$2
    local ip_adress=$3

    response=$(curl -X POST "http://localhost:3000/v1/cluster-onboarding/configure-ingress" \
        -H "Content-Type: application/json" \
        -d "{
        "tenantName": $tenant_name,
        "clusterToken": $cluster_token,
        "ip": $ip_adress
        }" \
        -w "%{http_code}" \
        -o response.json \
        --silent)

    if [ "$response" == "200" ]; then
        echo "Istio installed successfully"
    else
        echo "Failed to install istio response code: $response"
        return 1
    fi
}

# Function to guide the user through the installation process
installation_guide() {
    local tenant_name=$1
    local cluster_token=$2
    print_yellow "Starting TrueFoundry agent installation..."
    echo
    
    # Check if Helm is installed
    check_helm_installed
    
    # Check if Kubernetes cluster is reachable
    check_kubernetes_cluster
    
    # Check if kubectl context is set and confirm with the user
    check_kubectl_context
    
    # Guide the user through installing Argocd chart if not already installed
    print_yellow "Let's start by installing Argocd..."
    
    if check_argocd_crds_installed; then
        # ArgoCD CRDs are already installed, skip the entire ArgoCD installation
        print_yellow "Skipping argocd installation."
    else
        helm repo add argo https://argoproj.github.io/argo-helm
        install_argocd_helm_chart
        install_helm_chart "argo" "argo-rollouts" "argo-rollouts" "2.25.0"
    fi
    
    if check_istio_crds_installed; then
        # Istio CRDs are already installed, skip the entire Istio installation
        print_yellow "Skipping istio charts installation."
    else
        ip_adress=get_cluster_ip()
        install_istio "$tenant_name" "$cluster_token" "$ip_adress" 
        # helm repo add istio https://istio-release.storage.googleapis.com/charts
        # install_helm_chart "istio" "base" "istio-system" "1.15.3"
        # install_helm_chart "istio" "istiod" "istio-system" "1.15.3"
    fi
    
    # Guide the user through installing Tfy-agent chart
    print_yellow "Next, we'll install the tfy-agent chart..."
    
    if check_chart_installed "tfy-agent" "tfy-agent"; then
        print_yellow "The 'tfy-agent' chart is already installed. Skipping tfy-agent installation."
    else
        helm repo add truefoundry https://truefoundry.github.io/infra-charts/
        install_helm_chart "truefoundry" "tfy-agent" "tfy-agent" "0.1.1" "$tenant_name" "$cluster_token"
    fi
    
    # Completion message
    print_green "Congratulations! The installation process is complete."
}

# Start the installation guide with tenantName and clusterToken as arguments
if [ $# -lt 2 ]; then
    echo "Error: Insufficient arguments. Please provide the tenantName and clusterToken."
    echo "Usage: $0 <tenantName> <clusterToken>"
    exit 1
fi

installation_guide "$1" "$2"