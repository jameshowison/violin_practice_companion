#!/bin/bash
# Turn a Debian-family Linux box (a Raspberry Pi 3 or later is plenty) into an
# AirPlay 2 test receiver that an agent can drive. See README.md.
#
# Normally run for you by `receiver.sh setup` on the Mac, which copies this
# folder and the agent's public key over and runs, on the box:
#   sudo MAC_IP=… PHONE_IPS=… RECEIVER_NAME=… bash airplay_receiver/setup_receiver.sh
#
# MAC_IP         the Mac's address (give it a DHCP reservation): the only place
#                the agent's key works from.
# PHONE_IPS      the test phones' addresses, comma-separated (reservations, and
#                the phone's "Private Wi-Fi Address" set to Fixed): the only
#                devices that can stream to the receiver.
# RECEIVER_NAME  the name the phone's AirPlay list shows (default
#                "AirPlay Test Speaker"; letters, digits, space, _ and -).
# CAP_MB         size of the capture filesystem (default: 2048, or a quarter of
#                the free space if less).
# agent_key.pub  next to this script: the agent's public key.
#
# Safe to re-run. Builds nqptp + shairport-sync (AirPlay 2) from pinned
# commits, plays into a FIFO, records it on request into its own
# size-limited filesystem, and adds two users: `airplay` (the ssh identity,
# locked to airplay-ctl) and `airplay-cap` (the capture daemon). It leaves
# other services, ssh users and ports alone, and checks that it did.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
[[ ${MAC_IP:-} =~ $ip_re ]] || { echo "set MAC_IP=<the Mac's LAN address>" >&2; exit 1; }
[[ -n ${PHONE_IPS:-} ]] || { echo "set PHONE_IPS=<phone address>[,<another>]" >&2; exit 1; }
IFS=, read -r -a phones <<< "$PHONE_IPS"
for p in "${phones[@]}"; do [[ $p =~ $ip_re ]] || { echo "bad phone IP: $p" >&2; exit 1; }; done
RECEIVER_NAME=${RECEIVER_NAME:-AirPlay Test Speaker}
[[ $RECEIVER_NAME =~ ^[A-Za-z0-9\ _-]{1,40}$ ]] || { echo "bad RECEIVER_NAME: $RECEIVER_NAME" >&2; exit 1; }
[[ -s $HERE/agent_key.pub ]] || { echo "no agent_key.pub next to this script" >&2; exit 1; }
grep -qE '^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( [^"]*)?$' "$HERE/agent_key.pub" \
  || { echo "agent_key.pub doesn't look like one public key" >&2; exit 1; }

NQPTP_TAG=1.2.4  NQPTP_SHA=591f425d9da69f1c4e09f3ad09611b758937b3e5
SPS_TAG=4.3.7    SPS_SHA=0b1c4391ffd398e7b145eb4b98416261380adeea
STAMP=/usr/local/share/airplay_receiver
mkdir -p "$STAMP"

echo "▶ packages"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git autoconf automake libtool pkg-config \
  libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev \
  libssl-dev libsoxr-dev libplist-dev libsodium-dev libavutil-dev \
  libavcodec-dev libavformat-dev uuid-dev libgcrypt20-dev xxd python3 nftables
apt-get install -y --no-install-recommends libplist-utils || true
# systemd.pc, which shairport-sync's install asks for the unit dir; without it
# that is blank and `make install` dies on `install -d` with no operand.
apt-get install -y --no-install-recommends systemd-dev || true
UNITDIR=$(pkg-config --variable=systemdsystemunitdir systemd 2>/dev/null || true)
UNITDIR=${UNITDIR:-/lib/systemd/system}

# Clone a tag, then refuse it unless it is the commit we pinned (tags can move).
# A checkout already at the pinned commit is kept, so a re-run reuses its build.
fetch_pinned() {  # dir url tag sha
  if [[ -d $1/.git && $(git -C "$1" rev-parse HEAD 2>/dev/null) == "$4" ]]; then
    echo "  reusing $1 at $4"; return
  fi
  rm -rf "$1"
  git clone --quiet --branch "$3" "$2" "$1"
  local got; got=$(git -C "$1" rev-parse HEAD)
  [[ $got == "$4" ]] || { echo "✘ $2 $3 is $got, pinned $4 — refusing" >&2; exit 1; }
}
built() { [[ $(cat "$STAMP/$1" 2>/dev/null) == "$2" ]] || [[ $(cat "/usr/local/share/airplay_pi/$1" 2>/dev/null) == "$2" ]]; }

mkdir -p /usr/local/src && cd /usr/local/src
echo "▶ nqptp $NQPTP_TAG"
if ! built nqptp "$NQPTP_SHA"; then
  fetch_pinned nqptp https://github.com/mikebrady/nqptp.git "$NQPTP_TAG" "$NQPTP_SHA"
  (cd nqptp && autoreconf -fi && ./configure --with-systemd-startup && make -j2 && make install)
fi
echo "$NQPTP_SHA" > "$STAMP/nqptp"
echo "▶ shairport-sync $SPS_TAG (AirPlay 2)"
if ! built shairport-sync "$SPS_SHA"; then
  fetch_pinned shairport-sync https://github.com/mikebrady/shairport-sync.git "$SPS_TAG" "$SPS_SHA"
  (cd shairport-sync
   [[ -f Makefile ]] || { autoreconf -fi && ./configure --sysconfdir=/etc \
     --with-alsa --with-pipe --with-soxr --with-avahi --with-ssl=openssl \
     --with-systemd --with-airplay-2; }
   make -j2 && make install systemdsystemunitdir="$UNITDIR")
fi
echo "$SPS_SHA" > "$STAMP/shairport-sync"
/usr/local/bin/shairport-sync -V | grep -q AirPlay2 || { echo "✘ no AirPlay2 in the build" >&2; exit 1; }
getent group shairport-sync >/dev/null || groupadd -r shairport-sync
getent passwd shairport-sync >/dev/null || \
  useradd -r -M -g shairport-sync -s /usr/sbin/nologin -G audio shairport-sync

echo "▶ users"
getent passwd airplay-cap >/dev/null || \
  useradd -r -M -d /nonexistent -s /usr/sbin/nologin -U airplay-cap
getent passwd airplay >/dev/null || \
  useradd -m -d /home/airplay -s /bin/sh -U -c "AirPlay test agent" airplay
usermod -s /bin/sh -p '*' -G airplay-cap airplay      # exactly these groups, no password
usermod -G '' airplay-cap
# The ssh user owns nothing it could rewrite: root's home, no dotfiles, no ~/.ssh.
rm -rf /home/airplay/.ssh
find /home/airplay -mindepth 1 -maxdepth 1 -name '.*' -exec rm -rf {} +
chown root:root /home/airplay; chmod 755 /home/airplay

echo "▶ capture filesystem (size-limited, so it can't fill /var)"
IMG=/var/lib/airplay-capture.img MNT=/var/lib/airplay-capture
if [[ ! -f $IMG ]]; then
  free_mb=$(df -Pm /var/lib | awk 'NR==2 {print $4}')
  size=${CAP_MB:-$(( free_mb / 4 < 2048 ? free_mb / 4 : 2048 ))}
  (( size >= 512 )) || { echo "✘ only ${free_mb} MB free on /var; want a ≥512 MB capture fs" >&2; exit 1; }
  fallocate -l "${size}M" "$IMG"; chmod 600 "$IMG"
  mkfs.ext4 -q -m 0 "$IMG"
fi
mkdir -p "$MNT"
grep -q "^$IMG " /etc/fstab || \
  echo "$IMG $MNT ext4 loop,nofail,nodev,nosuid,noexec 0 2" >> /etc/fstab
mountpoint -q "$MNT" || mount "$MNT"
install -d -m 2770 -o airplay-cap -g airplay-cap "$MNT" "$MNT/captures"
install -d -m 750 -o airplay-cap -g shairport-sync /var/lib/airplay-fifo
FIFO=/var/lib/airplay-fifo/audio.fifo
[[ -p $FIFO ]] || { rm -f "$FIFO"; mkfifo "$FIFO"; }
chown airplay-cap:shairport-sync "$FIFO"; chmod 620 "$FIFO"

echo "▶ scripts and sudoers"
install -m 755 -o root -g root "$HERE/airplay-ctl"        /usr/local/bin/airplay-ctl
install -m 755 -o root -g root "$HERE/airplay-root"       /usr/local/sbin/airplay-root
install -m 644 -o root -g root "$HERE/airplay_capture.py" /usr/local/lib/airplay_capture.py
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
echo 'airplay ALL=(root) NOPASSWD: /usr/local/sbin/airplay-root' > "$tmp"
visudo -cf "$tmp"
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/airplay

echo "▶ ssh: root-owned key file, Match block, verified"
install -d -m 755 -o root -g root /etc/ssh/authorized_keys
printf 'restrict,from="%s",command="/usr/local/bin/airplay-ctl" %s\n' \
  "$MAC_IP" "$(head -1 "$HERE/agent_key.pub")" > "$tmp"
install -m 644 -o root -g root "$tmp" /etc/ssh/authorized_keys/airplay
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config || \
  { echo "✘ sshd_config doesn't include sshd_config.d" >&2; exit 1; }
install -m 644 -o root -g root "$HERE/sshd_airplay.conf" /etc/ssh/sshd_config.d/zz-airplay.conf
undo_sshd() { rm -f /etc/ssh/sshd_config.d/zz-airplay.conf; echo "✘ sshd check failed: $1 — Match block removed, ssh untouched" >&2; exit 1; }
sshd -t || undo_sshd "syntax"
me=$(sshd -T -C "user=airplay,host=mac,addr=$MAC_IP")
grep -qx 'forcecommand /usr/local/bin/airplay-ctl' <<< "$me" || undo_sshd "airplay has no ForceCommand"
grep -qx 'authorizedkeysfile /etc/ssh/authorized_keys/%u' <<< "$me" || undo_sshd "airplay key file"
grep -qx 'permittty no' <<< "$me" || undo_sshd "airplay tty"
admin=${SUDO_USER:-root}
you=$(sshd -T -C "user=$admin,host=mac,addr=$MAC_IP")
grep -qx 'forcecommand none' <<< "$you" || undo_sshd "the Match block leaked onto $admin"
systemctl is-active -q ssh && systemctl reload ssh || true   # socket-activated sshd reads it per connection

echo "▶ firewall (receiver ports: phones only)"
allow=$(IFS=,; echo "${phones[*]}" | sed 's/,/, /g')
mkdir -p /etc/nftables.d
sed "s/@ALLOW@/$allow/" "$HERE/airplay-firewall.nft" > "$tmp"
nft -c -f "$tmp"
install -m 644 -o root -g root "$tmp" /etc/nftables.d/airplay.nft
install -m 644 "$HERE/airplay-firewall.service" /etc/systemd/system/airplay-firewall.service

echo "▶ config and services"
# Keep the distribution's config once, the first time we replace it.
if [[ -f /etc/shairport-sync.conf && ! -f /etc/shairport-sync.conf.orig ]] \
   && ! grep -qE 'airplay_receiver|airplay_pi' /etc/shairport-sync.conf; then
  cp /etc/shairport-sync.conf /etc/shairport-sync.conf.orig
fi
sed "s/@NAME@/$RECEIVER_NAME/" "$HERE/shairport-sync.conf" > "$tmp"
install -m 644 "$tmp" /etc/shairport-sync.conf
install -m 644 "$HERE/airplay-capture.service" /etc/systemd/system/airplay-capture.service
systemctl daemon-reload
systemctl enable airplay-firewall airplay-capture nqptp shairport-sync
systemctl restart airplay-firewall airplay-capture nqptp shairport-sync
sleep 2
systemctl --no-pager --lines=5 status airplay-firewall nqptp shairport-sync airplay-capture || true
echo "▶ check"
id airplay; id airplay-cap
ls -ld /home/airplay /etc/ssh/authorized_keys/airplay "$MNT"
df -h "$MNT" | tail -1
echo "✔ done — \"$RECEIVER_NAME\" should appear on ${PHONE_IPS} only"
