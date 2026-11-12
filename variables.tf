variable "allow_empty_policy" {
  type        = bool
  default     = false
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
}

variable "pa_rules_json_file_path" {
  description = "Path to the Private Access JSON export produced by `catocli export pa_rules` (data.policy.privateAccess.policy root)."
  type        = string
}
