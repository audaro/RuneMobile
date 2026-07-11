# GAP-B-2 — RuneLite api/hub version-pin review ledger.
#
# runelite.properties intentionally pins runelite.pluginhub.version + runelite.api.base to a version that
# LAGS gradle.properties' project.build.version. The pin exists because a newer minor's api path 404s
# (commit a310e583c8: "1.12.29 never released -> 404"). `git merge upstream/master` never rewrites our pin,
# so without this ledger the stale pin rides every future merge forward invisibly.
#
# check-hub-pin.sh fails the release gate when project.build.version advances past reviewed_project_version.
# When that happens: verify whether https://api.runelite.net/runelite-<newver> and
# repo.runelite.net/plugins/<newver> now resolve. If they do, lift the pin back to ${project.version} in
# runelite.properties; if they still 404, keep the pin. Either way, bump reviewed_project_version to re-arm.
#
# 2026-07-01 review at project 1.12.31: probed the newer api/hub paths; could not confirm they resolve
# (inconclusive from outside the client's exact request shape), so the known-good pin is RETAINED.
reviewed_project_version=1.12.31
pinned_hub_version=1.12.28
