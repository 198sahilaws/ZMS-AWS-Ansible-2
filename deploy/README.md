# Deploying this repo from the ZMS-AWS-LAB Terraform stack

This directory holds the glue to make the Terraform-provisioned Ansible control
node drive **this** repository (the push-based `ZMS-AWS-Ansible-1`). The stock
Terraform cloud-init used `ansible-pull local.yml`, which self-configures the
control node but **never pushes `site.yml` to the estate**, and it was missing
`boto3` and an env handoff. These changes fix that.

## What to change in the Terraform repo (ZMS-AWS-LAB-1)

1. **Point the control node at this repo.** In `terraform.tfvars`:

   ```hcl
   control_repo_url    = "https://github.com/198sahilaws/ZMS-AWS-Ansible-1.git"
   control_repo_branch = "main"
   ```

   (The stock `terraform.tfvars.example` leaves `control_repo_url = ""`, which
   configures **no** automation at all — the #1 reason "ansible did not work".)

2. **Replace the cloud-init** at `modules/ansible-control/cloud-init.yaml` with
   `ansible-control-cloud-init.yaml` from this directory. It:
   - installs `python3-boto3` (amazon.aws needs boto3/botocore — was missing);
   - clones this repo to `/opt/control-repo` and installs its collections;
   - writes `/etc/ansible/estate.env` (region + secret name) for the units;
   - installs and enables the repo's **systemd timers** instead of `ansible-pull`
     (`ansible-bootstrap.timer` self-converges; `ansible-estate.timer` runs
     `site.yml` against the estate);
   - runs the self-converge once on first boot.

   No changes to `modules/ansible-control/main.tf` are needed — it already passes
   `aws_region`, `secret_name`, `secret_arn`, `control_repo_url`, and
   `control_repo_branch` into the template.

3. `terraform apply` (or taint/replace just the control node:
   `terraform apply -replace=module.ansible_control[0].aws_instance.control`).

## Why the old path failed (summary)

| Symptom | Cause |
|---|---|
| Nothing ran | `control_repo_url` empty → cloud-init added no cron; and there was no first-boot run. |
| `Could not find local.yml` | `ansible-pull` needs `local.yml`; this repo had none (now added as a shim). |
| Estate never configured | `ansible-pull` runs `local.yml` on localhost only — it never pushes `site.yml`. |
| `boto3/botocore` import error | cloud-init never installed boto3; amazon.aws inventory + `aws_secret` fail. |
| Secret not found / wrong region | env handoff (`/etc/ansible/secrets.env`) was written but never sourced; region fell back to `eu-west-3` while the stack is in `us-east-1`. |

## Manual verification on the node

```bash
sudo cat /etc/ansible/estate.env                 # AWS_REGION + ANSIBLE_SECRET_NAME present
systemctl list-timers 'ansible-*'
journalctl -u ansible-bootstrap.service -n 50 --no-pager
cd /opt/control-repo && ansible-inventory --graph # os_linux / os_windows populated
```
