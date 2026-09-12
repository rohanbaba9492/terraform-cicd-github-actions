# Terraform CI/CD with GitHub Actions

`terraform plan` on every pull request with the output posted as a PR comment,
`terraform apply` on merge to `main`, and no AWS access keys stored anywhere.

The `.github/` directory is self-contained and drops into any Terraform repo
with an S3 backend and a `backend.hcl`.

---

## The pipeline

```
  PR opened ──► Plan workflow
                  ├─ fmt -check
                  ├─ init (S3 backend)
                  ├─ validate
                  ├─ tflint
                  ├─ trivy config scan
                  └─ plan ──► comment on PR (updated in place, not appended)
                                  │
                          human reviews the diff
                                  │
                             merge to main
                                  │
                          Apply workflow
                                  ├─ environment: production ── waits for approval
                                  ├─ re-plan
                                  ├─ count destroys ──► warn
                                  └─ apply ──► outputs to job summary

  nightly ──► Drift workflow ──► plan -detailed-exitcode ──► open/update an issue
```

---

## Before the roles exist

Each workflow starts with a `preflight` job that checks whether its AWS role
secret is set. If it is not, the real job is skipped and the run finishes
green with a note in the job summary rather than failing on an authentication
error.

This exists because the `secrets` context is not available in a job-level
`if:` — GitHub only exposes `github`, `needs`, `vars` and `inputs` there. The
check has to run inside a step and pass its result forward as a job output.

`oidc-bootstrap/` is also excluded from the apply trigger. It creates the
roles the pipeline authenticates with, so applying it *through* that pipeline
would be a circular dependency.

---

## Setup

### 1. Create the OIDC roles

```bash
cd oidc-bootstrap
terraform init
terraform apply \
  -var github_repo=terraform-multi-az-vpc \
  -var state_bucket=tfstate-multi-az-vpc-123456789012 \
  -var lock_table=tfstate-locks-multi-az-vpc
```

If the OIDC provider already exists in the account (it is one per account, not
one per repo), pass `-var create_oidc_provider=false`.

### 2. Set the repository secrets

```bash
terraform output -raw gh_cli_commands | bash
```

Two secrets, both of them role ARNs. **No `AWS_ACCESS_KEY_ID` and no
`AWS_SECRET_ACCESS_KEY` anywhere in this repository.**

### 3. Turn on branch protection

See [`docs/branch-protection.md`](docs/branch-protection.md). Without it the
workflows are decoration — anyone can push to `main` and trigger an apply of
something that was never planned.

---

## Why OIDC instead of access keys

An `AWS_SECRET_ACCESS_KEY` in repository secrets is a permanent credential
sitting in a system you do not fully control. It does not expire. It is
readable by every workflow in the repo, including one added in a PR. Rotating
it is a manual task nobody does.

With OIDC, GitHub mints a short-lived JWT describing the run — which repo,
which ref, which workflow — and AWS trades it for credentials valid for one
hour. Nothing persistent exists to leak.

The trust policy is where the security actually lives:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:myorg/myrepo:*"]      # plan role
}
```

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:myorg/myrepo:ref:refs/heads/main"]   # apply role
}
```

Note `StringEquals` on the apply role, not `StringLike`. A wildcard there —
`repo:myorg/myrepo:*` — would let a pull request branch assume the write role,
which defeats the entire split.

**The mistake to avoid:** omitting the `sub` condition altogether. With only
the `aud` condition, *any* GitHub repository on the internet can assume your
role. This shows up in a lot of tutorials.

### Two roles, not one

| | Plan role | Apply role |
|---|---|---|
| Permissions | `ReadOnlyAccess` + state bucket RW | `PowerUserAccess` + scoped IAM |
| Assumable from | any ref, including PRs | `refs/heads/main` only |
| Used by | Plan workflow, Drift workflow | Apply workflow |

A single role would mean every PR author — including someone who opened a PR
from a fork — holds production write credentials for the duration of the run.

The plan role still needs `s3:PutObject` and `dynamodb:PutItem`, because
`terraform plan` writes the lock and can refresh state. Read-only in the AWS
sense does not mean read-only against the backend.

---

## Design decisions

**The PR comment is updated, not appended.**
`listComments` finds the existing comment by a hidden HTML marker and calls
`updateComment`. A 12-commit PR otherwise accumulates 12 plan comments and
reviewers stop reading them.

**Truncation is from the front, not the back.**
GitHub caps a comment at 65,535 characters. A large plan blows through that.
Naive truncation keeps the head and loses the `Plan: 3 to add, 1 to change, 2
to destroy.` line at the end — the one line that matters. This keeps the tail.

**The comment posts before the job fails.**
Every gate uses `continue-on-error: true`, the comment step runs on
`if: always()`, and a final step fails the job explicitly. Fail fast on `fmt`
and the reviewer gets a red X with no explanation and has to dig through the
Actions log.

**Apply re-plans instead of consuming the PR's plan artifact.**
Reusing the reviewed plan file is the theoretically correct answer and I tried
it first. A saved plan is bound to the state serial it was created from, so if
anything else applied between review and merge, `terraform apply tfplan` fails
with "saved plan is stale" — and on a busy repo that is most merges. The
compromise here: re-plan on `main`, then count destroys from
`terraform show -json` and surface the number in the job summary. If the count
differs from what was reviewed, it is visible.

**Destroy counting uses `show -json | jq`, not grep.**
Grepping `Plan: .* to destroy` breaks the moment output formatting changes or
a resource name happens to contain the word. The JSON plan is a stable
interface.

**`concurrency` groups differ between plan and apply.**
Plan uses `cancel-in-progress: true` keyed on the PR number — a new push makes
the old plan irrelevant. Apply uses `cancel-in-progress: false` on a single
shared group — cancelling an in-flight apply leaves a held DynamoDB lock and
possibly half-created infrastructure.

**tflint and Trivy warn but do not block.**
Both are `continue-on-error: true` deliberately. A scanner that blocks on its
first false positive teaches the team to bypass CI, and that habit is worse
than the findings. They post to the comment table so a reviewer sees them.
Once findings are at zero, flipping `exit-code` to `1` is a one-line change —
and doing it in that order is the point.

**`if: always()` on the summary and comment steps.**
Without it, a failed plan produces no comment at all, and the failure mode a
reviewer sees is silence.

---

## Notes from building it

**`Resource not accessible by integration` on the comment step.**
The default `GITHUB_TOKEN` is read-only for `pull-requests`. Adding
`pull-requests: write` to `permissions:` fixes it. Note that declaring a
`permissions:` block at all switches the token from the repo default to
*exactly* what is listed, so `contents: read` has to be listed too or checkout
breaks.

**`Not authorized to perform sts:AssumeRoleWithWebIdentity`.**
Two separate causes, and the error is identical for both:
1. `id-token: write` missing from `permissions` — GitHub never mints the JWT.
2. The `sub` condition does not match the actual claim. Debug it by printing
   the claim:
   ```yaml
   - run: echo "$ACTIONS_ID_TOKEN_REQUEST_URL"
   ```
   or read the exact `sub` value in CloudTrail's failed `AssumeRoleWithWebIdentity`
   event. Guessing the format wastes an hour; CloudTrail shows it in seconds.

**The plan role could not write state.**
`ReadOnlyAccess` looks like the obvious policy for a plan job. `terraform plan`
takes the DynamoDB lock and may write a refreshed state, so it fails with
`AccessDenied` on `dynamodb:PutItem`. Hence the separate `state_access` policy
attached to both roles.

**Fork PRs got no credentials at all.**
By design — `pull_request` from a fork runs with a read-only token and no
secrets. `pull_request_target` would fix it and is a well-known vulnerability:
it runs the *base* branch's workflow with *write* permissions and secrets,
against the fork's code. Do not use it for this. The correct answer is that
fork PRs do not get a plan, and a maintainer re-runs it after review.

**A cancelled apply left a stuck lock.**
Cancelling the workflow mid-`apply` kills the process without releasing the
DynamoDB lock, and every subsequent run fails with `Error acquiring the state
lock`. Recovery:
```bash
terraform force-unlock <LOCK_ID>   # the ID is in the error message
```
Verify nothing is actually still running first — force-unlocking a live apply
is how state gets corrupted. This is why the apply concurrency group has
`cancel-in-progress: false`.

---

## Narrowing the apply role for real use

`PowerUserAccess` is the lab shortcut. To scope it properly, derive the action
list from the plan itself:

```bash
terraform show -json tfplan \
  | jq -r '.resource_changes[].type' \
  | sort -u
```

Map each resource type to its service prefix and grant only those. Then run
the pipeline with the narrowed policy and read CloudTrail for
`AccessDenied` events — that is faster and more accurate than reasoning about
which actions a resource needs.

The `DenySelfEscalation` statement stays regardless of how wide the allow list
gets. An explicit `Deny` beats any `Allow`, so a pipeline that can create IAM
roles still cannot create a user, mint an access key, or rewrite its own trust
policy.
