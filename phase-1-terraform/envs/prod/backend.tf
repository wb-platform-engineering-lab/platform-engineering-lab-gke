terraform {
  backend "gcs" {
    bucket = "platform-eng-lab-will-tfstate"
    prefix = "prod/terraform/state"
  }
}
