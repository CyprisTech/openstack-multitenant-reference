# Publish a domain through the shared entry point

The entry point routes each domain by SNI to the tenant that serves it, without decrypting the traffic: the tenant keeps its certificates, and the client address reaches it in a PROXY protocol v2 header.

1. **Declare the domain in the tenant**: `domains` of a [`vm`](../../stacks/tenants/vm/README.md) tenant, `cluster.domains` of a [`kubernetes`](../../stacks/tenants/kubernetes/README.md) tenant. Apply the tenant: its `published_domains` output now lists the domain and the tenant's service address ([ADR-0006](../adr/0006-exposure.md)).
2. **Publish**:

   ```bash
   OS_CLOUD=<entry of the entry point's project> scripts/publish-domains.sh
   ```

   The script gathers the `published_domains` output of every tenant and applies the entry point: the routes are metadata items of its instances, updated in place, which a timer on each instance renders into Traefik's configuration within seconds. No instance is replaced, no request is lost. It stops if a deployed tenant's state lacks the output (apply the tenant first) and refuses to remove every published domain (`--allow-empty` to force).
3. **Point the domain to the entry point**: an A record on its public address (`tofu output load_balancer` in `stacks/shared/entry-point`), with a short TTL.
4. **Check**: `curl --resolve <domain>:443:<public IP> https://<domain>/` reaches the tenant, and the [isolation test](check-isolation.md) still passes.

The tenant obtains the domain's certificate itself, with an ACME DNS-01 challenge on its zone ([ADR-0006](../adr/0006-exposure.md), D5).

Limits of the shared entry point (no TLS termination, no layer 7 routing, SNI required, about 120 domains): [trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point). A tenant that should not depend on it exposes its service address itself (`exposure = "public"` of the `vm` and `kubernetes` stacks).
