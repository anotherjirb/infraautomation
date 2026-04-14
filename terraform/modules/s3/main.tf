# ── S3 Buckets ─────────────────────────────────────────────

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Terraform state / CI/CD metadata bucket ──────────────────
resource "aws_s3_bucket" "tfstate" {
  bucket        = var.tfstate_bucket_name
  force_destroy = true
  tags          = { Name = var.tfstate_bucket_name }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-deployments"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ── Application assets bucket ────────────────────────────────
resource "aws_s3_bucket" "assets" {
  bucket        = var.assets_bucket_name
  force_destroy = true
  tags          = { Name = var.assets_bucket_name }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "expire-old-assets"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}
