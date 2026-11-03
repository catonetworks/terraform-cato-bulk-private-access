output "deployment_summary" {
  description = "Counts of managed Private Access objects."
  value = {
    rules = length(cato_private_access_rule.rules)
  }
}

output "rule_ids" {
  description = "Map of rule name to rule id."
  value       = { for name, r in cato_private_access_rule.rules : name => r.id }
}
