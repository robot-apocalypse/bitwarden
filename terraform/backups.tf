# Off-host backups. Before 2026-10-02 every backup lived on the instance's
# only EBS volume (DeleteOnTermination = true), so losing the instance lost
# the vault and every copy of it.

resource "aws_s3_bucket" "backups" {
  bucket = "peakscale-vaultwarden-backups"
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Write-only: the host can add backups but cannot list, read, or delete them,
# so a compromised host cannot wipe its own off-box copies. Archives include
# rsa_key.pem, so reads stay with humans.
resource "aws_iam_role_policy" "backup_put" {
  name = "vaultwarden-backup-put"
  role = aws_iam_role.ssm.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.backups.arn}/vaultwarden/*"
    }]
  })
}

# Daily crash-consistent EBS snapshots of the whole instance, as a second,
# independent mechanism. SQLite in WAL mode recovers cleanly from these.
resource "aws_iam_role" "dlm" {
  name = "vaultwarden-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "vaultwarden" {
  description        = "Daily snapshots of the vaultwarden instance"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]
    target_tags    = { Name = "vaultwarden" }

    schedule {
      name      = "daily-7"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["11:00"]
      }

      retain_rule {
        count = 7
      }

      tags_to_add = { SnapshotCreator = "dlm-vaultwarden" }
    }
  }
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}
