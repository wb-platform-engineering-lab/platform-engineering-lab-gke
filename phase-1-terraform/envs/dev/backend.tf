terraform {
  backend "gcs" {
    bucket = "platform-eng-lab-will-tfstate"
    prefix = "dev/terraform/state"
  }
}
