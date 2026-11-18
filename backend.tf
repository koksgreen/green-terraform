terraform {
  backend "s3" {
    bucket       = "green-test-file"
    key          = "green-test-file/terraform.tfstate"
    region       = "eu-north-1"
  }
}