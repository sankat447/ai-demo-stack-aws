# =============================================================================
#  Remote State Backend — S3 + DynamoDB locking
#  Run scripts/bootstrap-state.sh once to create the backend resources.
# =============================================================================
terraform {
  backend "s3" {
    bucket         = "ai-demo-stack-tfstate"
    key            = "demo/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ai-demo-stack-tflock"
    encrypt        = true
  }
}
