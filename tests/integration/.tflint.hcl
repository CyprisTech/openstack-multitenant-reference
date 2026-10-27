# Configuration for the test configurations: the recommended preset, without the documentation
# rules of the stacks (short, self-describing declarations).
config {
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
