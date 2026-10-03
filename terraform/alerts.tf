# Dead-man's-switch alerting. Every mechanism on this host that failed so far
# (Watchtower, the backup container, unattended-upgrades) ran while doing
# nothing and reported success. These alarms live in CloudWatch, not on the
# host, and fire on the ABSENCE of a success signal, so a broken script, a
# stopped timer, and a dead instance all alert the same way.

resource "aws_sns_topic" "alerts" {
  name = "vaultwarden-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "ian@peakscale.solutions"
}

# Scoped to the Vaultwarden namespace: the host can publish its heartbeat
# but not write into any other metric namespace.
resource "aws_iam_role_policy" "heartbeat" {
  name = "vaultwarden-heartbeat"
  role = aws_iam_role.ssm.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["cloudwatch:PutMetricData"]
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "Vaultwarden" } }
    }]
  })
}

# vaultwarden-backup.sh publishes BackupSuccess=1 only after the snapshot
# passed integrity_check AND the S3 upload succeeded. No datapoint for 26
# hours (daily run + slack) means no good backup.
resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  alarm_name          = "vaultwarden-backup-missing"
  alarm_description   = "No successful Vaultwarden backup in 26h. Check: journalctl -u vaultwarden-backup.service (via SSM), instance status, and s3://peakscale-vaultwarden-backups/vaultwarden/. See docs/upgrade-runbook.md."
  namespace           = "Vaultwarden"
  metric_name         = "BackupSuccess"
  dimensions          = { Label = "daily" }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 26
  datapoints_to_alarm = 26
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# The daily backup reports UpdateOK=0 when the weekly updater's last run
# failed or is over 8 days old. Missing data is ignored: if the host stops
# reporting entirely, backup_missing already fires.
resource "aws_cloudwatch_metric_alarm" "update_failed" {
  alarm_name          = "vaultwarden-update-failed"
  alarm_description   = "Vaultwarden weekly update failed or has not succeeded in 8 days. Check: journalctl -u vaultwarden-update.service (via SSM) and /var/lib/vaultwarden-ops/update-status. See docs/upgrade-runbook.md."
  namespace           = "Vaultwarden"
  metric_name         = "UpdateOK"
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
