#!/bin/bash
#
# SPIKE wubiuefi — validation du boot loop-monté sur Ubuntu 26.04
# ================================================================
#
# Question posée : le mécanisme historique de Wubi (racine dans un FICHIER
# `root.disk` posé sur une partition NTFS, monté par l'initramfs via le
# paramètre `loop=`) fonctionne-t-il encore avec Ubuntu 26.04 ?
#
# Ce script NE PILOTE PAS l'installeur Ubuntu. C'est le coeur de la question :
# depuis 24.04 les images utilisent le snap `ubuntu-desktop-bootstrap`
# (subiquity/curtin), qui ne connait ni preseed debconf ni recette partman.
# Les pièces d'installation de wubiuefi (preseed.lupin, autopartition-loop)
# n'ont donc plus de cible. On contourne : on déballe le squashfs et on
# configure en chroot.
#
# En revanche la moitié BOOT est intacte en amont : initramfs-tools 26.04
# gère toujours `loop=` (scripts/local, mount -o loop ligne ~263) et traite
# explicitement ntfs/vfat. C'est ce que ce spike vérifie pour de vrai.
#
# Produit $WORK/disk.img : un disque GPT contenant
#   p1  ESP  (FAT32)  -> grub EFI + config loopback
#   p2  NTFS          -> /ubuntu/disks/root.disk (ext4) = la racine Linux
# soit exactement la topologie d'une machine Windows après un Wubi.
#
set -euo pipefail

ISO_URL="${ISO_URL:-https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso}"
WORK="${WORK:-/mnt/spike}"
IMG="$WORK/disk.img"
IMG_SIZE="${IMG_SIZE:-24G}"
ROOTDISK_SIZE="${ROOTDISK_SIZE:-9G}"
ROOT_PASSWORD="${ROOT_PASSWORD:-spike}"
INSTALL_DIR="ubuntu"                       # \ubuntu\disks\root.disk, comme Wubi

ISO="$WORK/$(basename "$ISO_URL")"
MNT_ISO="$WORK/mnt/iso"
MNT_HOST="$WORK/mnt/host"                  # la "partition Windows"
MNT_ROOT="$WORK/mnt/root"                  # l'intérieur de root.disk
MNT_ESP="$WORK/mnt/esp"

say()  { echo ""; echo "=== $* ==="; }
fail() { echo "!!! ECHEC : $*" >&2; exit 1; }

cleanup() {
	set +e
	for m in "$MNT_ROOT/dev/pts" "$MNT_ROOT/dev" "$MNT_ROOT/proc" "$MNT_ROOT/sys" \
	         "$WORK/mnt/merged" "$WORK"/mnt/layers/* \
	         "$MNT_ROOT" "$MNT_ESP" "$MNT_HOST" "$MNT_ISO"; do
		mountpoint -q "$m" 2>/dev/null && umount -l "$m"
	done
	[ -n "${LOOPDEV:-}" ] && losetup -d "$LOOPDEV" 2>/dev/null
	set -e
}
trap cleanup EXIT

mkdir -p "$WORK" "$MNT_ISO" "$MNT_HOST" "$MNT_ROOT" "$MNT_ESP"

# ---------------------------------------------------------------- 1. ISO
say "1. Récupération de l'ISO"
if [ ! -f "$ISO" ]; then
	curl -L --retry 5 --retry-delay 5 -o "$ISO" "$ISO_URL"
else
	echo "déjà présente ($(du -h "$ISO" | cut -f1))"
fi
mount -o ro,loop "$ISO" "$MNT_ISO"
echo "contenu de casper/ :"
ls -1 "$MNT_ISO/casper/" | sed 's/^/    /'

# Les couches squashfs s'empilent : base d'abord, puis chaque surcouche.
# 26.04 : plus de casper/filesystem.squashfs (ce que cherche encore
# isolist.ini de wubiuefi), mais minimal + une ou plusieurs couches.
# On EXCLUT les couches ".live" et ".installer" : session live / installeur,
# inutiles dans un système installé.
mapfile -t LAYERS < <(
	find "$MNT_ISO/casper" -maxdepth 1 -name '*.squashfs' -printf '%f\n' \
	| grep -v -- '\.live\.' | grep -v -- '\.installer\.' \
	| awk '{ print length"\t"$0 }' | sort -n | cut -f2-
)
[ ${#LAYERS[@]} -gt 0 ] || fail "aucune couche squashfs exploitable"
say "Couches retenues (dans l'ordre d'empilement)"
printf '    %s\n' "${LAYERS[@]}"

# ------------------------------------------------------- 2. disque + partitions
say "2. Fabrication du disque (GPT : ESP + NTFS)"
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"
sgdisk --clear \
	--new=1:1MiB:+512MiB --typecode=1:ef00 --change-name=1:ESP \
	--new=2:0:0          --typecode=2:0700 --change-name=2:WINDOWS \
	"$IMG" >/dev/null
LOOPDEV=$(losetup --find --show --partscan "$IMG")
echo "loop : $LOOPDEV"
ESP_PART="${LOOPDEV}p1"
NTFS_PART="${LOOPDEV}p2"

mkfs.vfat -F32 -n ESP "$ESP_PART" >/dev/null
mkfs.ntfs --quick --label WINDOWS "$NTFS_PART" >/dev/null
NTFS_UUID=$(blkid -s UUID -o value "$NTFS_PART")
[ -n "$NTFS_UUID" ] || fail "pas d'UUID sur la partition NTFS"
echo "UUID NTFS : $NTFS_UUID"

# Monter en NTFS comme le fera l'initramfs (pilote noyau ntfs3)
mount -t ntfs3 "$NTFS_PART" "$MNT_HOST" || mount -t ntfs-3g "$NTFS_PART" "$MNT_HOST" \
	|| fail "impossible de monter la partition NTFS"

# --------------------------------------------------------------- 3. root.disk
say "3. Création de $INSTALL_DIR/disks/root.disk ($ROOTDISK_SIZE, ext4)"
mkdir -p "$MNT_HOST/$INSTALL_DIR/disks"
ROOTDISK="$MNT_HOST/$INSTALL_DIR/disks/root.disk"
truncate -s "$ROOTDISK_SIZE" "$ROOTDISK"
mkfs.ext4 -F -q -L wubi-root "$ROOTDISK"
mount -o loop "$ROOTDISK" "$MNT_ROOT" || fail "loop-mount de root.disk impossible"

say "4. Empilement des couches squashfs dans root.disk"
# Les couches ne s'extraient PAS l'une par-dessus l'autre : unsquashfs échoue
# sur les liens durs déjà présents ("failed to create hardlink, File exists").
# On les superpose donc en overlay, comme le fait casper au démarrage, puis on
# recopie la vue fusionnée. -H préserve les liens durs, -A/-X les ACL et
# attributs étendus (indispensables : le système cible en dépend).
mkdir -p "$WORK/mnt/layers"
LOWER=""
i=0
for layer in "${LAYERS[@]}"; do
	i=$((i + 1))
	LDIR="$WORK/mnt/layers/$i"
	mkdir -p "$LDIR"
	mount -t squashfs -o ro,loop "$MNT_ISO/casper/$layer" "$LDIR" \
		|| fail "montage de $layer impossible"
	echo "--- couche $i : $layer"
	# overlayfs : la plus à gauche l'emporte, donc on empile à l'envers
	LOWER="$LDIR${LOWER:+:$LOWER}"
done
mkdir -p "$WORK/mnt/merged"
mount -t overlay overlay -o "lowerdir=$LOWER" "$WORK/mnt/merged" \
	|| fail "overlay impossible (lowerdir=$LOWER)"
echo "vue fusionnée montée, recopie vers root.disk ..."
rsync -aHAXx --numeric-ids "$WORK/mnt/merged/" "$MNT_ROOT/"
umount "$WORK/mnt/merged"
for d in "$WORK"/mnt/layers/*; do mountpoint -q "$d" && umount "$d"; done
df -h "$MNT_ROOT" | tail -1

# ------------------------------------------------------------------ 5. chroot
say "5. Configuration du système (chroot)"
mount --bind /dev     "$MNT_ROOT/dev"
mount --bind /dev/pts "$MNT_ROOT/dev/pts"
mount -t proc  proc  "$MNT_ROOT/proc"
mount -t sysfs sysfs "$MNT_ROOT/sys"

# fstab : la racine est le fichier loop-monté, comme chez Wubi
cat > "$MNT_ROOT/etc/fstab" << EOF
# Wubi : la racine est un fichier sur la partition hôte, monté en loop
/host/$INSTALL_DIR/disks/root.disk  /       ext4  loop,errors=remount-ro  0  1
UUID=$NTFS_UUID                     /host   ntfs3 defaults,nofail        0  0
proc                                /proc   proc  defaults               0  0
EOF

echo "spike" > "$MNT_ROOT/etc/hostname"

# L'initramfs doit savoir monter la NTFS : sans ce module, pas de /host,
# donc pas de root.disk, donc pas de boot.
mkdir -p "$MNT_ROOT/etc/initramfs-tools"
grep -qs '^ntfs3' "$MNT_ROOT/etc/initramfs-tools/modules" 2>/dev/null \
	|| printf 'ntfs3\nloop\next4\n' >> "$MNT_ROOT/etc/initramfs-tools/modules"

# Patch lupin (data/custom-installation/patch/loop-remount) : remplace le
# `mount -o loop` par un losetup explicite. Le motif existe toujours tel quel
# dans initramfs-tools 26.04 ; s'il ne s'applique pas, on continue avec le
# code d'origine, qui gère lui aussi `loop=`.
LOCAL_SCRIPT="$MNT_ROOT/usr/share/initramfs-tools/scripts/local"
OLD='mount ${roflag} -o loop -t ${FSTYPE} ${LOOPFLAGS} "/host/${LOOP#/}" '
NEW='loopdev=`losetup -f`; losetup ${loopdev} "/host/${LOOP#/}"; mount ${roflag} -t ${FSTYPE} ${LOOPFLAGS} ${loopdev} '
if grep -qF "$OLD" "$LOCAL_SCRIPT"; then
	sed -i "s%$OLD%$NEW%g" "$LOCAL_SCRIPT"
	echo "patch loop-remount : APPLIQUE"
else
	echo "patch loop-remount : motif absent, on garde le code d'origine"
fi

cat > "$MNT_ROOT/tmp/inchroot.sh" << CHROOT
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
echo "root:$ROOT_PASSWORD" | chpasswd
# console série : indispensable pour lire le boot depuis QEMU
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true
KVER=\$(ls /lib/modules | sort -V | tail -1)
echo "noyau détecté : \$KVER"
update-initramfs -u -k \$KVER
ls -l /boot/
CHROOT
chmod +x "$MNT_ROOT/tmp/inchroot.sh"
chroot "$MNT_ROOT" /tmp/inchroot.sh || fail "configuration en chroot"
rm -f "$MNT_ROOT/tmp/inchroot.sh"

# noms exacts du noyau et de l'initrd, pour les écrire en dur dans grub
KERNEL=$(cd "$MNT_ROOT/boot" && ls vmlinuz-* | sort -V | tail -1)
INITRD=$(cd "$MNT_ROOT/boot" && ls initrd.img-* | sort -V | tail -1)
[ -n "$KERNEL" ] && [ -n "$INITRD" ] || fail "noyau ou initrd introuvable dans root.disk"
echo "noyau  : $KERNEL"
echo "initrd : $INITRD"

sync
umount "$MNT_ROOT/dev/pts" "$MNT_ROOT/dev" "$MNT_ROOT/proc" "$MNT_ROOT/sys"
umount "$MNT_ROOT"

# -------------------------------------------------------------- 6. bootloader
say "6. Bootloader EFI (équivalent wubildr)"
mount "$ESP_PART" "$MNT_ESP"
mkdir -p "$MNT_ESP/EFI/BOOT"

# grub embarque sa config : il ouvre root.disk depuis la NTFS via `loopback`,
# puis charge noyau et initrd DEPUIS L'INTERIEUR de l'image ext4.
cat > "$WORK/grub-embed.cfg" << EOF
insmod part_gpt
insmod ntfs
insmod ext2
insmod loopback
search --no-floppy --fs-uuid --set=hostdev $NTFS_UUID
loopback lo (\$hostdev)/$INSTALL_DIR/disks/root.disk
set root=(lo)
set prefix=(lo)/boot/grub
configfile /boot/grub/grub.cfg
EOF

grub-mkimage -O x86_64-efi -p "(lo)/boot/grub" -o "$MNT_ESP/EFI/BOOT/BOOTX64.EFI" \
	-c "$WORK/grub-embed.cfg" \
	part_gpt part_msdos ntfs fat ext2 loopback search search_fs_uuid normal linux \
	configfile echo test terminal serial gfxterm all_video ls cat halt reboot sleep
[ -s "$MNT_ESP/EFI/BOOT/BOOTX64.EFI" ] || fail "grub-mkimage n'a rien produit"

# La config lue une fois dans l'image ext4. `loop=` est LE paramètre historique
# de Wubi : il dit à l'initramfs de monter la partition hôte puis d'y
# loop-monter ce fichier comme racine.
mount -o loop "$ROOTDISK" "$MNT_ROOT"
mkdir -p "$MNT_ROOT/boot/grub"
cat > "$MNT_ROOT/boot/grub/grub.cfg" << EOF
set timeout=2
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
menuentry "Ubuntu (Wubi loop)" {
	insmod part_gpt
	insmod ntfs
	insmod ext2
	insmod loopback
	search --no-floppy --fs-uuid --set=hostdev $NTFS_UUID
	loopback lo (\$hostdev)/$INSTALL_DIR/disks/root.disk
	set root=(lo)
	linux /boot/$KERNEL root=UUID=$NTFS_UUID loop=/$INSTALL_DIR/disks/root.disk rootfstype=ext4 ro console=ttyS0,115200 console=tty0 systemd.show_status=1
	initrd /boot/$INITRD
}
EOF
cat "$MNT_ROOT/boot/grub/grub.cfg"
sync
umount "$MNT_ROOT"
umount "$MNT_ESP"

say "TERMINE"
echo "image     : $IMG"
echo "UUID NTFS : $NTFS_UUID"
echo "racine    : /$INSTALL_DIR/disks/root.disk ($ROOTDISK_SIZE)"
ls -lh "$IMG"
