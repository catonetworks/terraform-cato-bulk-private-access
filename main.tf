# terraform-cato-bulk-private-access
#
# Bulk-manages the Cato Private Access (privateAccess) policy from one JSON
# export produced by `catocli export pa_rules`:
#   rules[]            rule wrappers ({audit, rule, properties}; ids retained
#                      for brownfield import)
#   rules_in_policy[]  THE ordering table ({index_in_policy, rule_name})
#
# Flat ordered rule list - the terraform private-access surface has no
# sections yet ("1st phase") and no sub-policies. cato_private_access_rule
# saves and publishes per rule; cato_private_access_rule_bulk applies the
# ordering and republishes on changes.
#
# NOTE: the account-level policy enable toggle (cato_private_access_policy)
# is intentionally NOT managed here - enable the policy separately.

locals {
  pa_json = jsondecode(file("${var.pa_rules_json_file_path}"))
  pa      = local.pa_json.data.policy.privateAccess.policy

  rules_data_raw      = try(local.pa.rules, [])
  rules_in_policy_raw = try(local.pa.rules_in_policy, [])

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  rule_order = {
    for row in local.rules_in_policy_raw : row.rule_name => row.index_in_policy
  }

  # Move/publish resource input: {name, index} per rule.
  bulk_rule_data = {
    for name, rw in local.rules_by_name : name => {
      name  = name
      index = try(local.rule_order[name], 0)
    }
  }

  # Rule-body translation (API camelCase -> provider snake_case). Entity refs
  # are name-or-id ({name} from the exporter; {id} when the live name contains
  # a backslash).
  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name        = rw.rule.name
        description = try(rw.rule.description, "")
        enabled     = try(rw.rule.enabled, true)
        action      = try(rw.rule.action.action, "ALLOW")
        applications = [
          for a in try(rw.rule.applications, []) :
          (can(a.application.name) ? { name = a.application.name } : { id = a.application.id })
        ]
        source = {
          users = [
            for x in try(rw.rule.source.user, []) :
            can(x.name) ? { name = x.name } : { id = x.id }
          ]
          user_groups = [
            for x in try(rw.rule.source.usersGroup, []) :
            can(x.name) ? { name = x.name } : { id = x.id }
          ]
        }
        tracking = {
          event = { enabled = try(rw.rule.tracking.event.enabled, false) }
          alert = merge(
            {
              enabled   = try(rw.rule.tracking.alert.enabled, false)
              frequency = try(rw.rule.tracking.alert.frequency, "HOURLY")
            },
            try(length(rw.rule.tracking.alert.subscriptionGroup), 0) > 0 ? {
              subscription_group = [for x in rw.rule.tracking.alert.subscriptionGroup : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {},
            try(length(rw.rule.tracking.alert.webhook), 0) > 0 ? {
              webhook = [for x in rw.rule.tracking.alert.webhook : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {},
            try(length(rw.rule.tracking.alert.mailingList), 0) > 0 ? {
              mailing_list = [for x in rw.rule.tracking.alert.mailingList : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {}
          )
        }
      },
      try(length(rw.rule.connectionsOriginList), 0) > 0 ? {
        connection_origins = rw.rule.connectionsOriginList
      } : {},
      try(length(rw.rule.country), 0) > 0 ? {
        countries = [for x in rw.rule.country : can(x.name) ? { name = x.name } : { id = x.id }]
      } : {},
      try(length(rw.rule.device), 0) > 0 ? {
        devices = [for x in rw.rule.device : can(x.name) ? { name = x.name } : { id = x.id }]
      } : {},
      try(length(rw.rule.platform), 0) > 0 ? {
        platforms = rw.rule.platform
      } : {},
      try(rw.rule.schedule, null) != null ? {
        schedule = merge(
          { active_on = try(rw.rule.schedule.activeOn, "ALWAYS") },
          try(rw.rule.schedule.customTimeframe, null) != null ? {
            custom_timeframe = {
              from = rw.rule.schedule.customTimeframe.from
              to   = rw.rule.schedule.customTimeframe.to
            }
          } : {},
          try(rw.rule.schedule.customRecurring, null) != null ? {
            custom_recurring = {
              days = rw.rule.schedule.customRecurring.days
              from = rw.rule.schedule.customRecurring.from
              to   = rw.rule.schedule.customRecurring.to
            }
          } : {}
        )
      } : {},
      anytrue([
        try(rw.rule.activePeriod.useEffectiveFrom, false),
        try(rw.rule.activePeriod.useExpiresAt, false),
        try(rw.rule.activePeriod.effectiveFrom, null) != null,
        try(rw.rule.activePeriod.expiresAt, null) != null,
        ]) ? {
        active_period = merge(
          {
            use_effective_from = try(rw.rule.activePeriod.useEffectiveFrom, false)
            use_expires_at     = try(rw.rule.activePeriod.useExpiresAt, false)
          },
          try(rw.rule.activePeriod.effectiveFrom, null) != null ? { effective_from = rw.rule.activePeriod.effectiveFrom } : {},
          try(rw.rule.activePeriod.expiresAt, null) != null ? { expires_at = rw.rule.activePeriod.expiresAt } : {}
        )
      } : {},
      try(rw.rule.userAttributes.riskScore, null) != null ? {
        user_attributes = {
          risk_score = {
            category = try(rw.rule.userAttributes.riskScore.category, "ANY")
            operator = try(rw.rule.userAttributes.riskScore.operator, "GTE")
          }
        }
      } : {}
    )
  }
}

resource "cato_private_access_rule" "rules" {
  for_each = local.rules_by_name

  name               = each.key
  description        = local.rule_bodies[each.key].description
  enabled            = local.rule_bodies[each.key].enabled
  action             = local.rule_bodies[each.key].action
  applications       = local.rule_bodies[each.key].applications
  source             = local.rule_bodies[each.key].source
  tracking           = local.rule_bodies[each.key].tracking
  connection_origins = try(local.rule_bodies[each.key].connection_origins, null)
  countries          = try(local.rule_bodies[each.key].countries, null)
  devices            = try(local.rule_bodies[each.key].devices, null)
  platforms          = try(local.rule_bodies[each.key].platforms, null)
  schedule           = try(local.rule_bodies[each.key].schedule, null)
  active_period      = try(local.rule_bodies[each.key].active_period, null)
  user_attributes    = try(local.rule_bodies[each.key].user_attributes, null)
}

# Ordering + republish on changes.
resource "cato_private_access_rule_bulk" "all_pa_rules" {
  depends_on = [cato_private_access_rule.rules]
  rule_data  = local.bulk_rule_data
}
