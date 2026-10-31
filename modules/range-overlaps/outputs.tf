output "overlaps" {
  description = "Pairs of overlapping ranges that share a scope, as \"<name> (<cidr>) and <name> (<cidr>)\"; empty when none."
  value       = local.overlaps
}
