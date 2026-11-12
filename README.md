# Terraform Cato Bulk Private Access Rules Module

This module allows you to bulk import Private Access (PA) rules from a JSON configuration file, and define the order of those rules within the Cato policy.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual Private Access rules with their configurations
- **Rule ordering**: A flat ordered list - the Private Access terraform surface has no sections yet ("1st phase") and no sub-policies

### Basic Example

```hcl
module "pa_rules" {
  source = "catonetworks/bulk-private-access/cato"

  pa_rules_json_file_path = "./config_data/all_pa_rules.json"
}
```

**Not managed:** the account-level policy toggle (`cato_private_access_policy`) - enable the policy separately (CMA or a standalone resource) if enforcement is wanted.

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.privateAccess.policy.rules[]` - Array of Private Access rules
- `data.policy.privateAccess.policy.rules_in_policy[]` - The ordering table for rules (there are no sections for this rule type)

#### Key Fields:

**Rules Array**: Each rule is a wrapper (`{audit, rule, properties}`, ids retained for brownfield import) whose `rule` object carries full attribute coverage: `action`, `applications`, `source` (users/user groups), `connectionsOriginList`, `country`, `device`, `platform`, `schedule`, `activePeriod`, `tracking`, `userAttributes.riskScore`.

The module translates several API field names to their Terraform equivalents: `action.action` -> `action`, `applications[].application` -> `applications`, `connectionsOriginList` -> `connection_origins`, `country` -> `countries`, `device` -> `devices`, `platform` -> `platforms`, `source.user`/`source.usersGroup` -> `source.users`/`source.user_groups`, `userAttributes.riskScore` -> `user_attributes.risk_score`.

> **Wrapper-shape compatibility:** `applications` in the `catocli export pa_rules` output is a wrapper object (`{application: [...]}`); this module also tolerates the older flat-list-of-wrappers shape for `applications`, so JSON exported by either shape is accepted without modification.

**Rules in Policy Array**: Maps rules to their order with:
- `index_in_policy`: The order of the rule within the overall policy
- `rule_name`: The name of the rule to place at that position

<details>
<summary>Click to expand full JSON configuration example</summary>

```json
{
  "data": {
    "policy": {
      "privateAccess": {
        "policy": {
          "enabled": true,
          "rules": [
            {
              "rule": {
                "name": "My PA Rule 1",
                "description": "My PA Rule 1",
                "enabled": true,
                "action": { "action": "ALLOW" },
                "applications": {
                  "application": [{ "name": "My Private App" }]
                },
                "source": {
                  "user": [],
                  "usersGroup": []
                },
                "tracking": {
                  "event": { "enabled": true },
                  "alert": { "enabled": false, "frequency": "HOURLY" }
                }
              }
            },
            {
              "rule": {
                "name": "My PA Rule 2",
                "description": "My PA Rule 2",
                "enabled": true,
                "action": { "action": "ALLOW" },
                "applications": {
                  "application": [{ "name": "My Other Private App" }]
                },
                "source": {
                  "user": [],
                  "usersGroup": []
                },
                "tracking": {
                  "event": { "enabled": true },
                  "alert": { "enabled": false, "frequency": "HOURLY" }
                }
              }
            }
          ],
          "rules_in_policy": [
            {
              "index_in_policy": 1,
              "rule_name": "My PA Rule 1"
            },
            {
              "index_in_policy": 2,
              "rule_name": "My PA Rule 2"
            }
          ]
        }
      }
    }
  }
}
```
</details>

### How Rule Ordering Works

Based on the example above:
1. **Rule 1** is placed at policy position 1
2. **Rule 2** is placed at policy position 2

The final policy structure will be:
```
├── My PA Rule 1
└── My PA Rule 2
```

Since this rule type has no sections or sub-policies, ordering is a single flat list driven entirely by `rules_in_policy[].index_in_policy`.

### Parameters

- `pa_rules_json_file_path`: Path to your JSON configuration file
- `allow_empty_policy`: (Optional) Safety guard - fails planning if the decoded JSON contains 0 rules, since that almost always means a truncated export, a renamed upstream JSON key, or an accidentally wrong-tenant JSON file. Set `true` only for an intentional greenfield/teardown config.

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing Private Access rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Private Access rules into the JSON format required by this module:

```bash
catocli export pa_rules --json-filename all_pa_rules.json
```

This command will generate a JSON file containing all your existing PA rules in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Once you have the JSON configuration file, you can adopt the existing rules into Terraform state. This is useful for:

- **Brownfield deployments**: Managing existing rules with Terraform
- **Backup and restore**: Restoring rules to a known good state after unintended changes
- **State management**: Bringing existing infrastructure under Terraform control

There are two ways to do this. This module's `for_each` state address is keyed by rule name, which is exactly what lets both options below line up directly against the exported JSON.

<details>
<summary>Option A (recommended) — native Terraform import blocks (migration.tf)</summary>

Requires Terraform >= 1.7. Create a one-shot `migration.tf` file beside your module call with one `import` block:

```hcl
# migration.tf — one-shot; delete after a successful `terraform apply` adopts
# the existing rules into state.

locals {
  migrate_json  = jsondecode(file("${path.module}/config_data/all_pa_rules.json"))
  migrate_rules = { for rw in local.migrate_json.data.policy.privateAccess.policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.migrate_rules
  to       = module.pa_rules.cato_private_access_rule.rules[each.key]
  id       = each.value
}

# cato_private_access_rule_bulk.all_pa_rules is plan-time ordering orchestration —
# it has no live object of its own, so it is never imported; it's created on
# the first apply after the resources above are adopted.
```

This module has no section resources - `cato_private_access_rule` is the only importable resource it manages (the Private Access terraform surface has no sections yet, per the Usage section above).

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 1 to add, 0 to change, 0 to destroy`. The "1 to add" is expected - it's `cato_private_access_rule_bulk.all_pa_rules`, which **cannot be imported** (the provider implements no `ImportState` for it; it's a plan-time ordering/publish resource with no independent API identity of its own) and is always created fresh on the first apply after an import. Any *other* "change" on an imported rule means the JSON export is stale relative to the live policy - **re-export** (`catocli export pa_rules`) and regenerate the locals above, rather than letting `terraform apply` overwrite the live policy with stale config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

Then delete `migration.tf` - its job is done, and leaving it in place just re-runs the same (no-op) import block on every future plan.

</details>

<details>
<summary>Option B — catocli import pa_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately - there is no plan preview before the import happens.

```bash
catocli import pa_rules_to_tf config_data/all_pa_rules.json --module-name=module.pa_rules
```

**Parameters:**
- `config_data/all_pa_rules.json`: Path to your exported JSON file
- `--module-name=module.pa_rules`: The name of your Terraform module instance

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export pa_rules --json-filename all_pa_rules.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "pa_rules" {
     source = "catonetworks/bulk-private-access/cato"

     pa_rules_json_file_path = "./config_data/all_pa_rules.json"
   }
   ```

3. **Adopt existing state (Option A — recommended):** create `migration.tf` with the import block shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import" (plus the un-importable bulk resource)
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import pa_rules_to_tf config_data/all_pa_rules.json --module-name=module.pa_rules` - imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export pa_rules --json-filename all_pa_rules.json
   # Compare with your existing JSON file to identify changes
   ```

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing, integration with other systems, and operational insights. Below are practical examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the Private Access deployment"
  value = {
    total_rules = module.pa_rules.deployment_summary.rules
  }
}

# Quick reference for rule IDs
output "quick_reference" {
  description = "Quick reference map for rule IDs"
  value = {
    rule_ids = module.pa_rules.rule_ids
  }
}

# Example: For integration with monitoring systems
output "monitoring_metrics" {
  description = "Example metrics that could be sent to monitoring systems"
  value = {
    deployment_timestamp = timestamp()
    total_pa_rules        = module.pa_rules.deployment_summary.rules
  }
}
```
</details>

### Output Use Cases

These example outputs demonstrate various practical applications:

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`monitoring_metrics`**: Metrics formatted for monitoring systems

## Known limitations

- `source.systemGroup` appears in exports for fidelity but has no terraform attribute yet - it is not managed.
- `active_period` is only passed when meaningful (a use_* flag or a date set); the provider rejects empty datetime strings.
- `applications` references private apps (`cato_private_app` / CMA-defined) - they must exist before rules referencing them apply.
- Run applies with `-parallelism=1` when several module instances share an account.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_private_access_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/private_access_rule) | resource |
| [cato_private_access_rule_bulk.all_pa_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/private_access_rule_bulk) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_pa_rules_json_file_path"></a> [pa\_rules\_json\_file\_path](#input\_pa\_rules\_json\_file\_path) | Path to the Private Access JSON export produced by `catocli export pa_rules` (data.policy.privateAccess.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Private Access objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
<!-- END_TF_DOCS -->
