variable "hcloud_token" {
  description = "Hetzner Cloud API token, read from ~/.config/hcloud/token by scripts/tf.sh"
  type        = string
  sensitive   = true
}

variable "name" {
  type    = string
  default = "sepolia-node"
}

variable "location" {
  description = "Hetzner location (fsn1 = Falkenstein)"
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "cpx42: 8 vCPU, 16 GB RAM"
  type        = string
  default     = "cpx42"
}

variable "volume_size_gb" {
  description = "Volume for the chain data. Can be grown later, not shrunk."
  type        = number
  default     = 1500
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/sepolia_hetzner.pub"
}

variable "admin_cidrs" {
  description = "Source addresses allowed to reach SSH (the admin machine's public IPv4)"
  type        = list(string)
}
