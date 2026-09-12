############################################
# GitHub Actions OIDC -> AWS IAM
############################################
# Creates the trust relationship that lets a GitHub Actions run assume an AWS
# role with NO long-lived access keys stored as repository secrets.
#
# Two roles, deliberately:
#   plan_role   - read-only, assumable from ANY branch (pull requests included)
#   apply_role  - write, assumable ONLY from refs/heads/main
#
# That split is the whole security story. A contributor who opens a PR from a
# fork gets a plan and nothing else; the write role is unreachable from their
# ref. One combined role would hand every PR author production write access.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Purpose   = "github-actions-oidc"
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # The subject claim GitHub sends. Format:
  #   repo:<owner>/<repo>:ref:refs/heads/<branch>
  #   repo:<owner>/<repo>:pull_request
  #   repo:<owner>/<repo>:environment:<name>
  repo = "${var.github_org}/${var.github_repo}"
}

############################################
# OIDC provider
############################################
# One per account. If you already have it, import instead of creating:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS stopped requiring an accurate thumbprint for this provider in 2023 --
  # it validates against its own trust store. The value is still a required
  # field, so this is the documented placeholder.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
}

############################################
# Plan role -- read only, any ref
############################################

data "aws_iam_policy_document" "plan_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike with repo:<org>/<repo>:* scopes this to ONE repository.
    # Omitting this condition entirely -- which plenty of blog posts do --
    # lets any GitHub repo on the internet assume your role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:*"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.role_name_prefix}-plan"
  description          = "Read-only role assumed by GitHub Actions for terraform plan."
  assume_role_policy   = data.aws_iam_policy_document.plan_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess cannot write the state file or take the lock, and `plan`
# needs to do both. This is the minimum extra grant.
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }

  statement {
    sid    = "StateObjectRW"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid    = "StateLock"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]

    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.lock_table}"]
  }
}

resource "aws_iam_policy" "state_access" {
  name        = "${var.role_name_prefix}-state-access"
  description = "Read/write the Terraform state object and take the DynamoDB lock."
  policy      = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

############################################
# Apply role -- write, main branch only
############################################

data "aws_iam_policy_document" "apply_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike, and pinned to main. A PR branch cannot
    # produce this subject claim, so a fork PR cannot reach this role no
    # matter what it puts in the workflow file.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${local.repo}:ref:refs/heads/main",
        "repo:${local.repo}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.role_name_prefix}-apply"
  description          = "Write role assumed by GitHub Actions for terraform apply on main."
  assume_role_policy   = data.aws_iam_policy_document.apply_assume.json
  max_session_duration = 3600
}

# PowerUserAccess is the pragmatic lab choice: everything except IAM.
# For a real pipeline, replace this with a policy scoped to the services the
# stack actually creates. The README explains how to derive it from the plan.
resource "aws_iam_role_policy_attachment" "apply_power" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# The stack creates IAM roles for EC2, so PowerUserAccess alone is not enough.
# Grant IAM narrowly rather than reaching for AdministratorAccess.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid    = "ManageServiceRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreateServiceLinkedRole",
    ]

    # Scoped by path so the pipeline cannot touch human or break-glass roles.
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/*",
    ]
  }

  # Explicitly deny the pipeline the ability to grant itself more power.
  statement {
    sid    = "DenySelfEscalation"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:AttachUserPolicy",
      "iam:UpdateAssumeRolePolicy",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "apply_iam" {
  name        = "${var.role_name_prefix}-apply-iam"
  description = "Narrow IAM permissions for the apply role, with an anti-escalation deny."
  policy      = data.aws_iam_policy_document.apply_iam.json
}

resource "aws_iam_role_policy_attachment" "apply_iam" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_iam.arn
}

resource "aws_iam_role_policy_attachment" "apply_state" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.state_access.arn
}
