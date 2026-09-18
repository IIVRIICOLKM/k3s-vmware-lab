terraform {
  required_version = "= 1.16.3"

  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "= 2.0.1"
    }
  }

  # State stays outside the repository; scripts/tf.sh supplies the path with -backend-config.
  backend "local" {}
}
