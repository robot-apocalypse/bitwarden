# One-time adoption of resources created from this config on 2026-04-11,
# whose local state was lost. Safe to delete once imported.
import {
  to = aws_security_group.vaultwarden
  id = "sg-0189cb2f3ba7921ea"
}

import {
  to = aws_iam_role.ssm
  id = "vaultwarden-ssm-v3"
}

import {
  to = aws_iam_role_policy_attachment.ssm
  id = "vaultwarden-ssm-v3/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_instance_profile.vaultwarden
  id = "terraform-20260411144220783300000001"
}

import {
  to = aws_instance.vaultwarden
  id = "i-0c20d9e1feb8aa8f8"
}

import {
  to = aws_route53_record.bitwarden
  id = "Z05138461ITQ58LOV0TYH_bitwarden.peakscale.solutions_A"
}
