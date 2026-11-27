# Publish a domain through the shared entry point

The entry point routes each domain by SNI to the tenant that serves it, without decrypting the traffic: the tenant keeps its certificates, and the client address reaches it in a PROXY protocol v2 header.

**With [`lz`](../../tools/landing-zone/README.md):** add the domain to the tenant's inputs (`domains`, or `cluster.domains`), then `lz deploy landing-zone.toml`: it applies the tenant, runs `scripts/request-domains.sh` for each tenant on the publication plane, then `scripts/publish-domains.sh` (steps 2 and 3 below). The review is then the change of the tenant's inputs in your deployment repository, before `lz deploy` runs.

By hand:

1. **Declare the domain in the tenant**: `domains` of a [`vm`](../../stacks/tenants/vm/README.md) tenant, `cluster.domains` of a [`kubernetes`](../../stacks/tenants/kubernetes/README.md) tenant. Apply the tenant: its `published_domains` output now lists the domain and the tenant's service address ([ADR-0006](../adr/0006-exposure.md)).
2. **Ask for the route**: the domains of the entry point are a reviewed input of its stack, the file `stacks/shared/entry-point/domains.auto.tfvars.json` of your deployment repository ([ADR-0016](../adr/0016-network-services-and-edge-by-level.md), D5). Write the tenant's domains into it, then commit it and open a merge request:

   ```bash
   scripts/request-domains.sh stacks/tenants/<tenant>
   ```

   The script reads the `published_domains` output of that tenant only and merges it into the file: a new domain is added, a domain already there takes the tenant's new service address. The reviewer sees which domain goes to which address; the plan of the entry point shows the same change. To withdraw a domain, remove its entry from the file, in a merge request too.
3. **Publish**, once the merge request is merged:

   ```bash
   OS_CLOUD=<entry of the entry point's project> scripts/publish-domains.sh
   ```

   The script plans the entry point, prints the domains the plan adds, changes or withdraws, and, when the plan is not empty, applies it: the routes are metadata items of its instances, updated in place, which a timer on each instance renders into Traefik's configuration within seconds. No instance is replaced, no request is lost. It reads no state of the tenants, and refuses to remove every published domain at once (`--allow-empty` to force).

   ```mermaid
   flowchart LR
       O["published_domains<br/>of a tenant"] --> Q["scripts/request-domains.sh"]
       Q --> F["domains.auto.tfvars.json<br/>merge request, reviewed"]
       F --> S["scripts/publish-domains.sh"]
       S --> TF["apply shared/entry-point<br/>metadata updated in place"]
       TF --> M["Nova metadata<br/>one route item per domain"]
       M -->|"every 10 s"| R["traefik-routes timer<br/>on each instance"]
       R --> D["/etc/traefik/dynamic/routes.yml<br/>reloaded by Traefik"]

       classDef shared fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a
       classDef tenant fill:#ffedd5,stroke:#c2410c,color:#7c2d12
       classDef other fill:#ffffff,stroke:#6b7280,color:#111827,stroke-dasharray:4 3
       classDef outside fill:#ffffff,stroke:#6b7280,color:#111827
       class O tenant
       class Q,S outside
       class F other
       class TF,M,R,D shared
   ```

   The timer leaves the routes untouched when the metadata service does not answer, or answers fewer routes than announced: an outage never removes a route.
4. **Point the domain to the entry point**: an A record on its public address (`tofu output load_balancer` in `stacks/shared/entry-point`), with a short TTL.
5. **Check**: `curl --resolve <domain>:443:<public IP> https://<domain>/` reaches the tenant, and the [isolation test](check-isolation.md) still passes.

The tenant obtains the domain's certificate itself, with an ACME DNS-01 challenge on its zone ([ADR-0006](../adr/0006-exposure.md), D5).

Limits of the shared entry point (no TLS termination, no layer 7 routing, SNI required, about 120 domains): [trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point). A tenant that should not depend on it exposes its service address itself (`exposure = "public"` of the `vm` and `kubernetes` stacks).
