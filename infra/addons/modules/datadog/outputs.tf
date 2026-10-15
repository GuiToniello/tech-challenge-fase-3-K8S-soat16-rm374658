# O url do provider e relativo (/dashboard/...).
output "dashboard_url" {
  value = "https://${local.app_host}${datadog_dashboard.this.url}"
}