variable "receiver" {
  description = "Base URL of the receiver, for example \"http://192.0.2.10:9090\": the agent pushes to <receiver>/api/v1/write. null: no agent."
  type        = string
  default     = null
}

variable "targets" {
  description = "Local endpoints to read, by job name, for example { node = [\"localhost:9100\"] }."
  type        = map(list(string))
  default     = { node = ["localhost:9100"] }
}

variable "labels" {
  description = "Labels added to every series, identifying the source (for example site, tenant, instance): with address translation, the receiver cannot tell instances apart by their address."
  type        = map(string)
  default     = {}
}

variable "scrape_interval" {
  description = "Interval between two readings of the local endpoints."
  type        = string
  default     = "30s"
}
