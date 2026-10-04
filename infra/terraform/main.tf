resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name = "${var.prefix}-${random_string.suffix.result}"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.40.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.40.0.0/20"]
}

# ---------------------------------------------------------------------------
# Container registry for the controller and any custom vLLM images
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = replace("acr${local.name}", "-", "")
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Azure Monitor: Log Analytics for container logs and node health
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# AKS cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = azurerm_subnet.aks.id
    only_critical_addons_enabled = false
    os_disk_size_gb              = 128
    temporary_name_for_rotation  = "systemtmp"

    node_labels = {
      "workload" = "system"
    }

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    pod_cidr            = "192.168.0.0/16"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  auto_scaler_profile {
    # Release idle GPU nodes quickly; they are the expensive part.
    scale_down_unneeded              = "5m"
    scale_down_delay_after_add       = "5m"
    scale_down_utilization_threshold = "0.5"
    skip_nodes_with_system_pods      = true
    expander                         = "least-waste"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# GPU node pool
#   - Tainted so only GPU workloads land on it.
#   - Labeled so the vLLM chart can target it.
#   - AKS installs the NVIDIA driver; the NVIDIA device plugin (installed by
#     scripts/bootstrap.sh) advertises nvidia.com/gpu to the scheduler.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = "gpua100"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.gpu_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  os_disk_size_gb       = 256

  auto_scaling_enabled = true
  min_count            = var.gpu_min_nodes
  max_count            = var.gpu_max_nodes
  node_count           = var.gpu_min_nodes

  priority        = var.gpu_use_spot ? "Spot" : "Regular"
  eviction_policy = var.gpu_use_spot ? "Delete" : null
  spot_max_price  = var.gpu_use_spot ? var.gpu_spot_max_price : null

  node_labels = merge(
    {
      "accelerator"        = "nvidia"
      "workload"           = "llm-inference"
      "nvidia.com/gpu.sku" = lower(replace(var.gpu_vm_size, "_", "-"))
    },
    # AKS adds this label to Spot nodes anyway; declaring it keeps plans clean.
    var.gpu_use_spot ? { "kubernetes.azure.com/scalesetpriority" = "spot" } : {}
  )

  node_taints = concat(
    ["nvidia.com/gpu=present:NoSchedule"],
    var.gpu_use_spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []
  )

  tags = var.tags
}

# Let the kubelet pull images from ACR.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# The model cache PVC (charts/vllm-inference) uses the built-in
# azurefile-csi-premium StorageClass, which provisions its own Premium Files
# account in the node resource group, so no storage account is declared here.
