locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/observability"
    },
    var.tags,
  )

  alarms = { for alarm in var.alarms : alarm.name => alarm }

  notification_list = var.enable_smn ? [huaweicloud_smn_topic.this[0].topic_urn] : []

  elb_stream_name = lookup(var.stream_names, "elb", "${var.names["lts_group"]}-elb-access")
}

resource "huaweicloud_lts_group" "this" {
  count = var.enable_lts ? 1 : 0

  group_name            = var.names["lts_group"]
  ttl_in_days           = var.log_retention_days
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_lts_stream" "elb" {
  count = var.enable_lts ? 1 : 0

  group_id              = huaweicloud_lts_group.this[0].id
  stream_name           = local.elb_stream_name
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_smn_topic" "this" {
  count = var.enable_smn ? 1 : 0

  name         = var.names["smn"]
  display_name = "LiteLLM gateway alarms"

  tags = local.tags
}

resource "huaweicloud_smn_subscription" "email" {
  count = var.enable_smn && var.alarm_email != "" ? 1 : 0

  topic_urn = huaweicloud_smn_topic.this[0].topic_urn
  protocol  = "email"
  endpoint  = var.alarm_email
  remark    = "LiteLLM gateway alarms"
}

resource "huaweicloud_ces_alarmrule" "this" {
  for_each = local.alarms

  alarm_name        = each.value.name
  alarm_description = each.value.description
  alarm_enabled     = true
  alarm_level       = each.value.level

  metric {
    namespace   = each.value.namespace
    metric_name = each.value.metric_name

    dimensions {
      name  = each.value.dimension_name
      value = each.value.dimension_value
    }
  }

  condition {
    period              = each.value.period
    filter              = each.value.filter
    comparison_operator = each.value.comparison_operator
    value               = each.value.value
    count               = each.value.count
    alarm_level         = each.value.level
  }

  dynamic "alarm_actions" {
    for_each = length(local.notification_list) > 0 ? [1] : []
    content {
      type              = "notification"
      notification_list = local.notification_list
    }
  }

  dynamic "ok_actions" {
    for_each = length(local.notification_list) > 0 ? [1] : []
    content {
      type              = "notification"
      notification_list = local.notification_list
    }
  }
}
