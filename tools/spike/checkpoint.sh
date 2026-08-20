#!/bin/bash
# Point de controle de l'etage 2.
#
# GitHub ne publie l'archive des journaux qu'a la fin du job : impossible de
# suivre un demarrage en direct. On decoupe donc l'attente en tranches, chacune
# suivie d'un televersement d'artefact -- ceux-la sont recuperables run en
# cours. On obtient une visibilite a la granularite de la tranche.
#
# Usage: checkpoint.sh <secondes>
set -u
WORK="${WORK:-/mnt/spike}"
DUREE="${1:-600}"
cd "$WORK"

# Verdict deja rendu par une tranche precedente : on ne fait rien.
if [ -f verdict ]; then
	echo "verdict deja rendu : $(cat verdict) -- tranche ignoree"
	exit 0
fi

QPID=$(cat qemu.pid 2>/dev/null || echo 0)
FIN=$(( $(date +%s) + DUREE ))

while [ "$(date +%s)" -lt "$FIN" ]; do
	if grep -qE "spike login:|Reached target Multi-User|Startup finished in" serial.log 2>/dev/null; then
		echo ok > verdict; break
	fi
	if grep -qE "Kernel panic|Dropping to a shell|ALERT!|does not exist|Entering emergency mode|Can.t find ext4|dracut-initqueue" serial.log 2>/dev/null; then
		echo echec > verdict; break
	fi
	if grep -qE "configfile a rendu la main|Minimal BASH-like line editing" serial.log 2>/dev/null; then
		echo echec-grub > verdict; break
	fi
	if ! kill -0 "$QPID" 2>/dev/null; then
		echo qemu-mort > verdict; break
	fi
	sleep 10
done

echo "--- taille de la console : $(wc -c < serial.log 2>/dev/null || echo 0) octets ---"
echo "--- 40 dernieres lignes ---"
tail -40 serial.log 2>/dev/null | tr -d '\000' || true
echo "--- jalons grub vus jusqu'ici ---"
grep -a "\[wubildr\]\|\[grub.cfg\]" serial.log 2>/dev/null | tail -10 || true
echo "--- etat : $( [ -f verdict ] && cat verdict || echo "toujours en cours" ) ---"
exit 0
