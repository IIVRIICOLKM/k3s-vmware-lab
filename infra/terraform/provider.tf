provider "vmworkstation" {
  endpoint = var.vmws_endpoint
  username = var.vmws_username
  password = var.vmws_password
  https    = true
  # "DEBUG" makes the provider print the password in plain text to the Terraform log.
  debug = "NONE"
}
