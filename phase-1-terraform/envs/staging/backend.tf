terraform {
  backend "gcs" {
    bucket = "platform-eng-lab-will-tfstate"
    prefix = "staging/terraform/state"
  }
}
