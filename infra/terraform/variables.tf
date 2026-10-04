variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "prefix" {
  description = "Short name prefix for all resources (lowercase letters and digits)."
  type        = string
  default     = "llminfer"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.prefix))
    error_message = "prefix must be 3-12 lowercase letters or digits."
  }
}

variable "location" {
  description = "Azure region. Pick one with quota for your GPU SKU (eastus, westus3, southcentralus...)."
  type        = string
  default     = "eastus"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Leave null to use the region default."
  type        = string
  default     = null
}

variable "system_vm_size" {
  description = "VM size for the system node pool (controller, Prometheus, Grafana)."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "system_node_count" {
  description = "Node count for the system pool."
  type        = number
  default     = 2
}

variable "gpu_vm_size" {
  description = <<-EOT
    GPU VM size. Defaults to one A100 80GB per node, which serves Llama 3 8B in fp16
    with room for a large KV cache. Cheaper option: Standard_NV36ads_A10_v5 (A10 24GB)
    with an AWQ-quantized model.
  EOT
  type        = string
  default     = "Standard_NC24ads_A100_v4"
}

variable "gpu_min_nodes" {
  description = "Minimum GPU nodes. 0 lets the cluster autoscaler release idle GPUs."
  type        = number
  default     = 0
}

variable "gpu_max_nodes" {
  description = "Maximum GPU nodes the cluster autoscaler may add."
  type        = number
  default     = 3
}

variable "gpu_use_spot" {
  description = "Run the GPU pool on Spot VMs (60-90% cheaper, can be evicted)."
  type        = bool
  default     = true
}

variable "gpu_spot_max_price" {
  description = "Max hourly Spot price in USD. -1 means pay up to the on-demand price."
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project = "gpu-llm-inference-platform"
    owner   = "aniket-malpure"
  }
}
