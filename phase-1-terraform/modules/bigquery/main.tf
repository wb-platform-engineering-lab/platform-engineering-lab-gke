resource "google_bigquery_dataset" "main" {
  dataset_id                  = replace("${var.project_id}_dataset", "-", "_")
  friendly_name               = "Platform Engineering Dataset"
  description                 = "Main BigQuery dataset for data platform pipelines"
  location                    = var.region
  delete_contents_on_destroy  = true
}
