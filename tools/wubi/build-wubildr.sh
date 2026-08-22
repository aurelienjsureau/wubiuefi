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

# La configuration passée par -c s'exécute dans le parseur MINIMAL de grub,
# avant le chargement du module `normal` : ni commentaires, ni `if`, ni `[`.
# D'où le montage de l'amont, repris ici : -c ne contient qu'une ligne, qui
# bascule en mode normal et lit la vraie configuration depuis un mini-disque
# embarqué (-m), cette fois avec le parseur complet.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# La version de grub fait partie de l'identité de l'image : le pilote NTFS a
# changé entre les versions, et c'est lui qu'on soupçonne. Elle doit donc être
# lisible à l'écran, sans avoir à retrouver comment l'image a été construite.
GRUBVER=$(grub-mkimage --version | grep -o '[0-9][0-9.]*' | head -1)
STAMP="${WUBILDR_STAMP:-$(git -C "$ICI" describe --always --dirty 2>/dev/null || echo inconnu)-$(date -u +%Y%m%d%H%M)}-grub$GRUBVER"
sed "s/@@STAMP@@/$STAMP/" "$CFG" > "$TMP/wubildr.cfg"

# Une faute de syntaxe dans cette configuration ne se verrait qu'au démarrage,
# sur la machine de l'utilisateur, sous la forme d'une invite `grub>` muette.
if command -v grub-script-check >/dev/null; then
	grub-script-check "$TMP/wubildr.cfg" || { echo "configuration refusée par grub-script-check" >&2; exit 1; }
fi

( cd "$TMP" && tar cf wubildr.tar wubildr.cfg )
printf 'normal (memdisk)/wubildr.cfg\n' > "$TMP/bootstrap.cfg"

# ntfs et ntfscomp : lecture de la partition Windows.
# exfat          : disques externes formatés par Windows, et repli quand le
#                  pilote NTFS de grub refuse la partition interne.
# loopback + ext2 : ouverture de root.disk et lecture de l'ext4 dedans.
# iso9660        : ouverture de l'ISO pendant la phase d'installation.
# search_fs_file : recherche par fichier, seule fiable sur NTFS.
grub-mkimage -O x86_64-efi -o "$OUT" -c "$TMP/bootstrap.cfg" -m "$TMP/wubildr.tar" \
	part_gpt part_msdos \
	ntfs ntfscomp exfat fat ext2 iso9660 loopback \
	search search_fs_file search_fs_uuid search_label \
	normal linux configfile echo test true sleep \
	memdisk tar \
	terminal serial gfxterm all_video video_bochs video_cirrus \
	ls cat halt reboot minicmd probe

# Auto-test : une image dont le bootstrap ou le stamp manquent est une image
# qui tombera sur l'invite `grub>` sur la machine de l'utilisateur. On refuse
# de la livrer.
for MARQUEUR in "normal (memdisk)/wubildr.cfg" "wubildr $STAMP"; do
	if ! grep -qa -- "$MARQUEUR" "$OUT"; then
		echo "image invalide : marqueur absent -- $MARQUEUR" >&2
		rm -f "$OUT"
		exit 1
	fi
done

echo "produit : $OUT ($(stat -c%s "$OUT") octets, version $STAMP)"
