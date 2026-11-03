# terraform-cato-bulk-private-access

Bulk-manages the Cato **Private Access (privateAccess)** policy from a single
JSON export: a flat ordered rule list (the terraform surface has no sections
yet — "1st phase" — and no sub-policies), ordered and republished via
`cato_private_access_rule_bulk`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_private_access_rule.rules` | rule name | full attribute coverage: action, applications, source (users/user_groups), connection_origins, countries, devices, platforms, schedule, active_period, tracking, user_attributes.risk_score |
| `cato_private_access_rule_bulk.all_pa_rules` | — | `rule_data` map `{name, index}` from the ordering table; republishes on changes |

**Not managed:** the account-level policy toggle
(`cato_private_access_policy`) — enable the policy separately (CMA or a
standalone resource) if enforcement is wanted.

## Input JSON

```bash
catocli export pa_rules --json-filename all_pa_rules.json
```

Root: `data.policy.privateAccess.policy` with `rules[]` (wrappers
`{audit, rule, properties}`, ids retained for brownfield import) and
`rules_in_policy[]` (`{index_in_policy, rule_name}` — the ordering table).
API→Terraform name shifts handled by the module: `action.action` → `action`,
`applications[].application` → `applications`, `connectionsOriginList` →
`connection_origins`, `country`→`countries`, `device`→`devices`,
`platform`→`platforms`, `source.user/usersGroup` → `source.users/user_groups`,
`userAttributes.riskScore` → `user_attributes.risk_score`.

## Usage

```hcl
module "pa_rules" {
  source                  = "catonetworks/bulk-private-access/cato"
  pa_rules_json_file_path = "${path.module}/config_data/all_pa_rules.json"
}
```

## Brownfield import

```bash
catocli import pa_rules_to_tf config_data/all_pa_rules.json \
  --module-name module.pa_rules --auto-approve
terraform plan   # expect: only cato_private_access_rule_bulk to add
```

## Known limitations

- `source.systemGroup` appears in exports for fidelity but has no terraform
  attribute yet — it is not managed.
- `active_period` is only passed when meaningful (a use_* flag or a date set);
  the provider rejects empty datetime strings.
- `applications` references private apps (`cato_private_app` /
  CMA-defined) — they must exist before rules referencing them apply.
- Run applies with `-parallelism=1` when several module instances share an
  account.
