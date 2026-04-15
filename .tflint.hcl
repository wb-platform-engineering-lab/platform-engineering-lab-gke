plugin "google" {
  enabled = true
  version = "0.29.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

config {
  # Scan each module independently — avoids cross-module variable resolution errors
  call_module_type = "none"
}
