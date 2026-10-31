# Module `plane-discovery`

Finds the address Neutron gave each attached router on a shared private plane ([How a tenant joins a plane](../../docs/concepts/plane-attachment.md), mode 2). An attached project cannot choose its address on a network it does not own, but the plane's owner — the hub project — sees every port on it: with the hub's credentials, this module lists the router interfaces of each attached project on its plane. It creates nothing; `stacks/shared/planes` routes the transit router to the addresses found.

The plane is read by its subnet's range — unique in the hub project, and never renamed — so that the first apply, before the plane exists, still plans: nothing is found then, and the next apply finds the routers attached since. The discovery relies on Neutron's default policy that lets a network's owner read the ports on it.
