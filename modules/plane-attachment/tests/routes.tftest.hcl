# The routes to the planes are on the transit router, the gateway of the subnet, never on the
# subnet (ADR-0013).

variables {
  attachment = {
    publication = { mode = "gateway", nat = true, cidr = "172.31.4.0/24", network_id = "n-pub", network_name = "publication", subnet_id = "s-pub" }
    internal = {
      mode   = "interface", nat = false, cidr = "172.31.8.0/24", network_id = "n-int", network_name = "internal", subnet_id = "s-int"
      routes = [{ destination = "10.40.0.0/16", next_hop = "172.31.8.1" }]
    }
  }
}

run "transit_router_holds_the_routes" {
  command = plan

  variables {
    planes         = ["publication", "internal"]
    default_router = "egress"
    routes         = { admin = ["192.0.2.0/24"] }
  }

  assert {
    condition     = output.routers["transit"].default_gateway == true && output.routers["transit"].internal_subnet == "main"
    error_message = "The transit router is the gateway of the subnet."
  }

  assert {
    condition = toset([for r in output.routers["transit"].routes : "${r.destination}>${r.next_hop_router}"]) == toset([
      "172.31.4.0/24>publication", "172.31.8.0/24>internal", "10.40.0.0/16>internal", "192.0.2.0/24>admin", "0.0.0.0/0>egress",
    ])
    error_message = "One route per plane range, per range routed through an interface plane, per stack destination, and the default route."
  }

  assert {
    condition     = alltrue([for k in ["publication", "internal"] : !contains(keys(output.routers[k]), "advertise_routes") && !contains(keys(output.routers[k]), "default_gateway")])
    error_message = "Plane routers push no host route and are not the gateway of the subnet."
  }

  assert {
    condition     = [for r in output.routers["internal"].routes : "${r.destination}>${r.next_hop}"] == ["10.40.0.0/16>172.31.8.1"] && length(output.routers["publication"].routes) == 0
    error_message = "An interface plane's router keeps its routes through the plane; a gateway plane's router has none."
  }
}

run "default_route_through_a_plane" {
  command = plan

  variables {
    planes         = ["publication"]
    default_router = "publication"
  }

  assert {
    condition     = contains([for r in output.routers["transit"].routes : "${r.destination}>${r.next_hop_router}"], "0.0.0.0/0>publication")
    error_message = "A tenant with no egress may send its default route to a plane's router."
  }
}

run "no_default_route" {
  command = plan

  variables {
    planes = ["publication"]
  }

  assert {
    condition     = length([for r in output.routers["transit"].routes : r if r.destination == "0.0.0.0/0"]) == 0
    error_message = "Without a default router, unknown destinations are dropped."
  }
}
