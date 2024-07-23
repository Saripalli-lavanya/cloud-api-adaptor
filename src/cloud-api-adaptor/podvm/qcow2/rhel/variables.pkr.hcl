// variables.pkr.hcl

// For those variables that you don't provide a default for, you must
// set them from the command line, a var-file, or the environment.

variable "cloud_init_image" {
  type    = string
  default = "cloud-init.img"
}

variable "cpus" {
  type    = string
  default = "2"
}

variable "disk_size" {
  type    = string
  default = "6144"
}

variable "cloud_image_checksum" {
  type    = string
  default = "d96622d77bcbab5526fd42e7d933ee851d239327946992a018b0bfc9fad777e7"
}

variable "cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
}

variable "memory" {
  type    = string
  default = "2048M"
}

variable "ssh_password" {
  type    = string
  default = "PeerP0d"
}

variable "ssh_username" {
  type    = string
  default = "peerpod"
}

variable "ssh_timeout" {
  type    = string
  default = "15m"
}

variable "qemu_image_name" {
  type    = string
  default = "peer-pod"
}

variable "qemu_binary" {
  type    = string
  default = "qemu-system-x86_64"
}

variable "machine_type" {
  type    = string
  default = "pc"
}

variable "boot_wait" {
  type    = string
  default = "10s"
}

variable "output_directory" {
  type    = string
  default = "output"
}

variable "podvm_distro" {
  type    = string
  default = env("PODVM_DISTRO")
}

variable "cloud_provider" {
  type    = string
  default = env("CLOUD_PROVIDER")
}

variable "se_boot" {
  type    = string
  default = env("SE_BOOT")
}

variable "target_arch" {
  type    = string
  default = env("ARCH")
}

variable "os_arch" {
  type    = string
  default = "x86_64"
}

variable "is_uefi" {
  type    = bool
  default = false
}

variable "uefi_firmware" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE.fd"
}

variable "disable_cloud_config" {
  type    = string
  default = env("DISABLE_CLOUD_CONFIG")
}

variable "cpu_type" {

  type    = string

  default = "Cascadelake-Server"

}


variable "ORG_ID" {

  type    = string

  default = "ORG_ID"

}



variable "ACTIVATION_KEY" {

  type    = string

  default = "ACTIVATION_KEY"

}

