#!/usr/bin/env bash
set -o pipefail;

# Based on https://github.com/sqrwf/openwrt-collectd-exec-dslstats
# Based on https://starbeamrainbowlabs.com/blog/article.php?article=posts/431-collectd-ping-exec.html
# Based on https://github.com/oweitman/openwrt-collectd-plc

# dont forget to chmod +x this file
# Append this to /etc/collectd/collectd.conf
#<Plugin exec>
#        Exec    "busybox:busybox"        "/etc/collectd/collectd-exec-ping.sh"
#</Plugin>

#/etc/sudoers
#Defaults:busybox !syslog
#busybox ALL=(ALL:ALL) NOPASSWD: /usr/sbin/mwan3*, /bin/ping*

#/etc/groups
#busybox:x:300:

#/etc/passwd
#busybox:x:300:0:root:/root:/bin/ash

#/etc/shadow
#busybox:x:0:0:99999:7:::

# Variables:
#   COLLECTD_INTERVAL   Interval at which to collect data
#   COLLECTD_HOSTNAME   The hostname of the local machine

# mwan3 interfaces
WAN1_IF="wan";
WAN2_IF="wanb";

declare targets=(
    "8.8.8.8"
)

ping_count="12";

###############################################################################
# for floating point calculations
calc() {
    awk "BEGIN{ printf \"%.2f\n\", $* }";
}

# Pure-bash alternative to sleep.
# Source: https://blog.dhampir.no/content/sleeping-without-a-subprocess-in-bash-and-how-to-sleep-forever
snore() {
    local IFS;
    [[ -n "${_snore_fd:-}" ]] || exec {_snore_fd}<> <(:);
    read ${1:+-t "$1"} -u $_snore_fd || :;
}

# Source: https://github.com/dylanaraps/pure-bash-bible#split-a-string-on-a-delimiter
split() {
    # Usage: split "string" "delimiter"
    IFS=$'\n' read -d "" -ra arr <<< "${1//$2/$'\n'}"
    printf '%s\n' "${arr[@]}"
}

# Source: https://github.com/dylanaraps/pure-bash-bible#use-regex-on-a-string
regex() {
    # Usage: regex "string" "regex"
    [[ $1 =~ $2 ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# Source: https://github.com/dylanaraps/pure-bash-bible#get-the-number-of-lines-in-a-file
# Altered to operate on the standard input.
count_lines() {
    # Usage: count_lines <"file"
    mapfile -tn 0 lines
    printf '%s\n' "${#lines[@]}"
}

# Source https://github.com/dylanaraps/pure-bash-bible#get-the-last-n-lines-of-a-file
tail() {
    # Usage: tail "n" "file"
    mapfile -tn 0 line < "$2"
    printf '%s\n' "${line[@]: -$1}"
}

###############################################################################

temp_dir="$(mktemp --tmpdir="/dev/shm" -d "collectd-exec-ping-XXXXXXX")";

on_exit() {
    rm -rf "${temp_dir}";
}
trap on_exit EXIT;

# $1 - target name
# $2 - url
check_target() {
    local target="${1}";
    local iface="${2}";

    tmpfile="$(mktemp --tmpdir="${temp_dir}" "ping-target-XXXXXXX")";

# we can't use ping directly as per this issue: https://github.com/openwrt/openwrt/issues/12278

#    ping -I "${iface}" -c "${ping_count}" "${target}" >"${tmpfile}";
    sudo mwan3 use "${iface}" ping "${target}" -q -c "${ping_count}" >"${tmpfile}";

    # readarray -t result < <(curl -sS --user-agent "${user_agent}" -o /dev/null --max-time 5 -w "%{http_code}\n%{time_total}\n" "${url}"; echo "${PIPESTATUS[*]}");
    mapfile -s "$((4))" -t file_data <"${tmpfile}";

# 3 packets transmitted, 3 packets received, 0% packet loss
# round-trip min/avg/max = 6.049/6.132/6.207 ms

    read -r _ _ _ _ _ _ loss _ _ < <(echo "${file_data[0]}");
    loss=$(calc "${loss/\%}"/100);

    read -r _ _ _ _ _ min avg max _ < <(echo "${file_data[1]//\// }");

#logger "PUTVAL \"${COLLECTD_HOSTNAME}/ping-exec/ping_droprate-${target}-${iface}\" N:${loss}";
#logger "PUTVAL \"${COLLECTD_HOSTNAME}/ping-exec/ping-${target}-${iface}\" N:${avg}";

    echo "PUTVAL \"${COLLECTD_HOSTNAME}/ping-exec/ping_droprate-${target}-${iface}\" N:${loss}";
    echo "PUTVAL \"${COLLECTD_HOSTNAME}/ping-exec/ping-${target}-${iface}\" N:${avg}";
    echo "PUTVAL \"${COLLECTD_HOSTNAME}/ping-exec/ping_stddev-${target}-${iface}\" N:0.0";

    rm "${tmpfile}";
}

while :; do
    for target in "${targets[@]}"; do
        # NOTE: We don't use concurrency here because that spawns additional subprocesses, which we want to try & avoid. Even though it looks slower, it's actually more efficient (and we don't potentially skew the results by measuring multiple things at once)
        check_target "${target}" "${WAN1_IF}"
        check_target "${target}" "${WAN2_IF}"
    done
    snore 1;
#    snore "${COLLECTD_INTERVAL}";
done