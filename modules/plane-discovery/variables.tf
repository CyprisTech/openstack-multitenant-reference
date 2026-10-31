variable "hub_project_id" {
  description = "Project owning the planes; its credentials see every port on them."
  type        = string
}

variable "planes" {
  description = "Interface planes, keyed by plane: the range of their subnet in the hub project (unique there)."
  type        = map(string)
}

variable "attachments" {
  description = "One entry per attachment and plane, keyed as you like: the plane and the attached project."
  type        = map(object({ plane = string, project_id = string }))
}
