# Branch protection setup

The workflows are only half the control. Without branch protection, anyone can
push straight to `main` and the apply workflow will happily run a change that
was never planned or reviewed.

## Via the CLI

```bash
gh api -X PUT repos/:owner/:repo/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Plan"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
```

## What each setting buys you

| Setting | Without it |
|---|---|
| `required_status_checks.contexts: ["Plan"]` | A PR whose plan errored can still be merged. |
| `strict: true` | A PR planned against an old `main` merges without re-planning against current state. This is the setting that prevents "it planned clean and applied badly." |
| `enforce_admins: true` | You bypass your own controls the first time you are in a hurry. |
| `dismiss_stale_reviews` | Reviewer approves, author pushes a `terraform destroy`-shaped change, it merges on the stale approval. |
| `allow_force_pushes: false` | History rewrite makes the audit trail between plan and apply worthless. |
| `required_linear_history` | Merge commits make it hard to say which commit an apply corresponded to. |

## Environment approval

The apply workflow declares `environment: production`. Add a required reviewer:

```
Settings → Environments → New environment → "production"
  → Required reviewers: <you>
  → Deployment branches: Selected branches → main
```

With that set, a merge to `main` **pauses** the apply job and waits for a
human click. The plan is already visible in the PR, so the approver is
approving something they have read.

"Deployment branches: main only" matters — it is a second, independent check
on top of the IAM trust policy condition. Defence in depth: if someone
misconfigures the IAM condition, GitHub still refuses to hand out the
production environment's context to a non-main ref.
