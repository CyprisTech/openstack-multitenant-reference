# Publish a domain through the shared entry point

The entry point routes each domain by SNI to the tenant that serves it, without decrypting the traffic: the tenant keeps its certificates, and the client address reaches it in a PROXY protocol v2 header.

1. **Declare the domain in the tenant**: `domains` of a [`vm`](../../stacks/tenants/vm/README.md) tenant, `cluster.domains` of a [`kubernetes`](../../stacks/tenants/kubernetes/README.md) tenant. Apply the tenant: its `routes` output now lists the domain and its backends.
2. **Publish**:

   ```bash
   OS_CLOUD=<entry of the entry point's project> scripts/publish-routes.sh
   ```

   The script gathers the `routes` output of every tenant and replaces the entry point instances one at a time, unhealthy ones first, never the last healthy one. Allow 5 to 8 minutes.
3. **Point the domain to the entry point**: an A record on its public address (`tofu output load_balancer` in `stacks/shared/entry-point`), with a short TTL.
4. **Check**: `curl --resolve <domain>:443:<public IP> https://<domain>/` reaches the tenant, and the [isolation test](check-isolation.md) still passes.

Limits of the shared entry point (no TLS termination, no layer 7 routing, SNI required): [trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point).
