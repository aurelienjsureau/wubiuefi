#!/bin/bash
#
# Fabrique wubildr (grubx64.efi) — à lancer sur une machine Linux, ou en CI.
# grub-mkimage et sbsign n'existent pas sous Windows : c'est la seule pièce de
# la chaîne qui doit être produite ailleurs, puis simplement copiée.
#
# Le résultat est autonome : la configuration (tools/wubi/wubildr.cfg) est
# embarquée dans l'image, il n'y a aucun fichier annexe à déposer sur l'ESP.
#
set -euo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
CFG="$ICI/wubildr.cfg"
OUT="${1:-$ICI/../../build/winboot/grubx64.efi}"

[ -f "$CFG" ] || { echo "configuration absente : $CFG" >&2; exit 1; }
command -v grub-mkimage >/dev/null || { echo "grub-mkimage manquant (paquet grub-efi-amd64-bin)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# ntfs et ntfscomp : lecture de la partition Windows.
# loopback + ext2 : ouverture de root.disk et lecture de l'ext4 dedans.
# iso9660        : ouverture de l'ISO pendant la phase d'installation.
# search_fs_file : recherche par fichier, seule fiable sur NTFS.
grub-mkimage -O x86_64-efi -p "(lo)/boot/grub" -o "$OUT" -c "$CFG" \
	part_gpt part_msdos \
	ntfs ntfscomp fat ext2 iso9660 loopback \
	search search_fs_file search_fs_uuid search_label \
	normal linux configfile echo test true sleep \
	terminal serial gfxterm all_video video_bochs video_cirrus \
	ls cat halt reboot minicmd probe

echo "produit : $OUT ($(stat -c%s "$OUT") octets)"
