#!/bin/bash
#
# Prépare un disque de test reproduisant la topologie d'une machine Windows :
# table GPT, partition EFI en FAT32, partition NTFS. Rien de plus — c'est
# ensuite tools/wubi/install-wubi.sh, le VRAI installeur, qui opère dessus.
#
# Sépare volontairement le banc d'essai du produit : ce qui est validé ensuite
# est bien le script destiné à la machine de l'utilisateur.
#
set -euo pipefail

WORK="${WORK:-/mnt/spike}"
IMG="$WORK/disk.img"
IMG_SIZE="${IMG_SIZE:-40G}"
MNT_HOST="$WORK/mnt/host"
MNT_ESP="$WORK/mnt/esp"

echo "=== Préparation du disque de test ($IMG_SIZE) ==="
mkdir -p "$MNT_HOST" "$MNT_ESP"
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"

sgdisk --clear \
	--new=1:1MiB:+512MiB --typecode=1:ef00 --change-name=1:ESP \
	--new=2:0:0          --typecode=2:0700 --change-name=2:WINDOWS \
	"$IMG" >/dev/null

LOOPDEV=$(losetup --find --show --partscan "$IMG")
echo "loop : $LOOPDEV"

mkfs.vfat -F32 -n ESP "${LOOPDEV}p1" >/dev/null
mkfs.ntfs --quick --label WINDOWS "${LOOPDEV}p2" >/dev/null

# Le noyau du runner Azure n'a pas ntfs3 : repli sur ntfs-3g, qui écrit un NTFS
# tout aussi authentique (relu ensuite par ntfs3 côté invité et par grub).
mount -t ntfs3 "${LOOPDEV}p2" "$MNT_HOST" 2>/dev/null \
	|| mount -t ntfs-3g "${LOOPDEV}p2" "$MNT_HOST" \
	|| { echo "montage NTFS impossible" >&2; exit 1; }
mount "${LOOPDEV}p1" "$MNT_ESP"

PARTUUID=$(blkid -s PARTUUID -o value "${LOOPDEV}p2")
cat > "$WORK/spike.env" << EOF
LOOPDEV=$LOOPDEV
HOST_PARTUUID=$PARTUUID
MNT_HOST=$MNT_HOST
MNT_ESP=$MNT_ESP
EOF

echo "NTFS montée sur $MNT_HOST (PARTUUID=$PARTUUID)"
echo "ESP  montée sur $MNT_ESP"
findmnt -n "$MNT_HOST" "$MNT_ESP"
