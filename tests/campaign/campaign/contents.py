"""What the projects of a scenario hold: the objects a campaign creates, listed in each project.
Checked empty before a campaign starts (preflight) and after its teardown (leftovers)."""

# Listings: a kind of object and the column holding its ID. The Octavia plugin names its columns
# in lower case. Images are kept (the Kubernetes node image).
LISTINGS = [
    (("server", "list"), "ID"),
    (("loadbalancer", "list"), "id"),
    (("floating", "ip", "list"), "ID"),
    (("router", "list"), "ID"),
    (("volume", "list"), "ID"),
    (("server", "group", "list"), "ID"),
]
# Listings that would also show the objects shared with the project: filtered by owner.
PROJECT_LISTINGS = [(("network", "list"), "ID"), (("port", "list"), "ID")]


def project_contents(ctx):
    """(found, failed): what each project of the scenario holds, and the listings that failed.
    A listing that fails is a failed check, not zero objects."""
    found, failed = [], []
    for cloud in ctx.clouds():
        try:
            project = ctx.openstack.project_id(cloud)
        except Exception as error:
            failed.append(f"{cloud}: token ({error})")
            continue
        listings = LISTINGS + [(listing + ("--project", project), column) for listing, column in PROJECT_LISTINGS]
        for listing, column in listings:
            what = " ".join(listing[:2])
            try:
                ids = ctx.openstack.ids(cloud, *listing, column=column)
            except Exception:
                failed.append(f"{cloud}: {what} (the listing itself failed)")
                continue
            if ids:
                found.append(f"{cloud}: {len(ids)} from {what}")
        try:
            groups = ctx.openstack.ids(cloud, "security", "group", "list", "--project", project, column="Name")
        except Exception:
            failed.append(f"{cloud}: security group list (the listing itself failed)")
        else:
            others = [g for g in groups if g != "default"]
            if others:
                found.append(f"{cloud}: {len(others)} security groups")
    return found, failed
