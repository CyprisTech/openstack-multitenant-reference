# Configuration for the stacks. The test configurations use tests/integration/.tflint.hcl.
config {
  # The stacks call the published module through git sources, which tflint does not download.
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Every variable and output of the stacks must be documented (see CONTRIBUTING.md).
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}
