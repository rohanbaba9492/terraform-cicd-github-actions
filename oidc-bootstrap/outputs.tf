output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository secret."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository secret."
  value       = aws_iam_role.apply.arn
}

output "gh_cli_commands" {
  description = "Run these to set the secrets without touching the web UI."
  value       = <<-EOT
    gh secret set AWS_PLAN_ROLE_ARN  --body "${aws_iam_role.plan.arn}"
    gh secret set AWS_APPLY_ROLE_ARN --body "${aws_iam_role.apply.arn}"
  EOT
}
