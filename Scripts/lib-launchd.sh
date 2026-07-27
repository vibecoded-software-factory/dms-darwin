# Shared launchd helpers. Sourced, never executed.
#
# Both installers in this repo (re)start agents - Scripts/install.sh for the
# daemon, Glue/install.sh for the shell and its six companions - and both got
# it wrong in the same way. The logic lives here once so a fix reaches both.

# (Re)start a launchd agent, and report truthfully whether it came up.
#
# Two failure modes, both of which have actually bitten:
#
#   - `bootout` is ASYNCHRONOUS. Bootstrapping before the teardown completes
#     fails with "Bootstrap failed: 5: Input/output error", and the agent is
#     then simply gone. Wait for the label to leave the domain first.
#   - Call sites used to swallow both commands with `2>/dev/null || true` and
#     print "(re)started" unconditionally. A lost race took the agent down while
#     the log claimed it was up - which is how dsearch and dcal were found dead
#     after a run that reported success for both.
#
# Returns non-zero on failure so a caller can decide. Optional extras append
# `|| true` and keep going; the ones the install cannot do without let `set -e`
# stop the script.
restart_agent() {
    ra_label="$1"
    ra_plist="$2"
    ra_domain="gui/$(id -u)"

    launchctl bootout "$ra_domain/$ra_label" 2>/dev/null || true

    # Up to ~3s. Teardown is normally instant; a busy agent can linger.
    ra_waited=0
    while launchctl print "$ra_domain/$ra_label" >/dev/null 2>&1 && [ "$ra_waited" -lt 10 ]; do
        sleep 0.3
        ra_waited=$((ra_waited + 1))
    done

    if ra_error="$(launchctl bootstrap "$ra_domain" "$ra_plist" 2>&1)"; then
        echo "   $ra_label (re)started"
        return 0
    fi

    echo "!! $ra_label FAILED to start: ${ra_error:-unknown launchctl error}" >&2
    return 1
}
