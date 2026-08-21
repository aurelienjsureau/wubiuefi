#!/bin/bash
#
# install-wubi.sh — installe Ubuntu dans un fichier posé sur une partition NTFS
# =============================================================================
#
# Remplace le moteur d'installation historique de wubiuefi, qui pilotait
# Ubiquity via un preseed debconf et une recette partman. Depuis 24.04 les
# images Ubuntu utilisent le snap `ubuntu-desktop-bootstrap` (subiquity/curtin)
# : ni preseed, ni partman, et un snap ne se patche pas. On ne pilote donc plus
# l'installeur du tout — on déballe le squashfs et on configure en chroot.
#
# À lancer en root depuis une session live Ubuntu (ou tout Linux disposant des
# outils listés plus bas), la partition Windows étant montée.
#
# Ce que ce script NE fait pas : modifier le BCD de Windows. Sous Windows,
# après coup :  bcdedit /set {bootmgr} path \EFI\wubildr\shimx64.efi
# ou utiliser --efi-entry pour poser directement une entrée UEFI.
#
set -euo pipefail

# ------------------------------------------------------------------ paramètres
ISO=""
HOST_MNT="/host"
ESP_MNT=""
SIZE_GB=30
SWAP_GB=2
USERNAME="ubuntu"
PASSWORD=""
HOSTNAME_="ubuntu-wubi"
LOCALE="fr_FR.UTF-8"
KEYBOARD="fr"
TIMEZONE="Europe/Paris"
INSTALL_DIR="ubuntu"
WITH_BOOTLOADER=1
EFI_ENTRY=0
CONSOLE_SERIAL=0

usage() {
	sed -n '3,20p' "$0" | sed 's/^# \?//'
	cat << 'USAGE'

Usage : install-wubi.sh --iso <fichier.iso> [options]

  --iso <chemin>       ISO Ubuntu (obligatoire)
  --host <point>       partition NTFS hôte, déjà montée   (défaut /host)
  --esp <point>        partition EFI, déjà montée         (défaut : détectée)
  --size <Go>          taille de root.disk                (défaut 30)
  --swap <Go>          taille de swap.disk, 0 = aucun     (défaut 2)
  --user <nom>         compte à créer                     (défaut ubuntu)
  --password <mdp>     mot de passe du compte             (demandé sinon)
  --hostname <nom>     nom de machine                     (défaut ubuntu-wubi)
  --locale <locale>    p. ex. fr_FR.UTF-8                 (défaut fr_FR.UTF-8)
  --keyboard <code>    disposition clavier                (défaut fr)
  --timezone <zone>    p. ex. Europe/Paris                (défaut Europe/Paris)
  --install-dir <nom>  dossier sur la NTFS                (défaut ubuntu)
  --no-bootloader      ne pas toucher à la partition EFI
  --efi-entry          ajouter une entrée UEFI (efibootmgr)
USAGE
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--iso) ISO="$2"; shift 2 ;;
		--host) HOST_MNT="$2"; shift 2 ;;
		--esp) ESP_MNT="$2"; shift 2 ;;
		--size) SIZE_GB="$2"; shift 2 ;;
		--swap) SWAP_GB="$2"; shift 2 ;;
		--user) USERNAME="$2"; shift 2 ;;
		--password) PASSWORD="$2"; shift 2 ;;
		--hostname) HOSTNAME_="$2"; shift 2 ;;
		--locale) LOCALE="$2"; shift 2 ;;
		--keyboard) KEYBOARD="$2"; shift 2 ;;
		--timezone) TIMEZONE="$2"; shift 2 ;;
		--install-dir) INSTALL_DIR="$2"; shift 2 ;;
		--no-bootloader) WITH_BOOTLOADER=0; shift ;;
		--efi-entry) EFI_ENTRY=1; shift ;;
		--console-serial) CONSOLE_SERIAL=1; shift ;;
		-h|--help) usage 0 ;;
		*) echo "argument inconnu : $1" >&2; usage 1 ;;
	esac
done

say()  { echo ""; echo "=== $* ==="; }
info() { echo "    $*"; }
fail() { echo ""; echo "!!! ÉCHEC : $*" >&2; exit 1; }

# ------------------------------------------------------------------ vérifications
say "Vérifications"
[ "$(id -u)" = "0" ] || fail "à lancer en root (sudo)"

# Réponses éventuellement déposées par l'interface Windows : elles évitent de
# tout resaisir dans la session live. Les options de la ligne de commande
# restent prioritaires.
REPONSES="$HOST_MNT/$INSTALL_DIR/install/wubi-reponses.conf"
if [ -f "$REPONSES" ]; then
	info "réponses trouvées : $REPONSES"
	while IFS='=' read -r cle val; do
		[ -n "$cle" ] || continue
		case "$cle" in
			user)     [ "$USERNAME" = "ubuntu" ] && USERNAME="$val" ;;
			password) [ -z "$PASSWORD" ] && PASSWORD="$val" ;;
			size)     [ "$SIZE_GB" = "30" ] && SIZE_GB="$val" ;;
			locale)   [ "$LOCALE" = "fr_FR.UTF-8" ] && LOCALE="$val" ;;
			keyboard) [ "$KEYBOARD" = "fr" ] && KEYBOARD="$val" ;;
		esac
	done < "$REPONSES"
fi
[ -n "$ISO" ] || { echo "--iso est obligatoire" >&2; usage 1; }
[ -f "$ISO" ] || fail "ISO introuvable : $ISO"

for t in unsquashfs rsync mkfs.ext4 blkid findmnt losetup chroot grub-mkimage; do
	command -v "$t" >/dev/null 2>&1 || fail "outil manquant : $t (paquets squashfs-tools rsync e2fsprogs util-linux grub-efi-amd64-bin)"
done

mountpoint -q "$HOST_MNT" || fail "$HOST_MNT n'est pas un point de montage — montez d'abord la partition Windows"
touch "$HOST_MNT/.wubi-test" 2>/dev/null || fail "$HOST_MNT n'est pas inscriptible.
    Si Windows est en veille prolongée ou que le démarrage rapide est actif, la
    NTFS reste marquée sale. Sous Windows : désactivez le démarrage rapide
    (Options d'alimentation), puis arrêt complet."
rm -f "$HOST_MNT/.wubi-test"

HOST_DEV=$(findmnt -n -o SOURCE --target "$HOST_MNT" | head -1)
[ -n "$HOST_DEV" ] || fail "impossible de déterminer le périphérique de $HOST_MNT"
HOST_FS=$(blkid -s TYPE -o value "$HOST_DEV" || echo inconnu)
# PARTUUID vient de la TABLE DE PARTITIONS, pas du système de fichiers : c'est
# la seule identification fiable ici, NTFS n'exposant pas d'UUID exploitable
# (grub search --fs-uuid échoue dessus, constaté à l'essai).
HOST_PARTUUID=$(blkid -s PARTUUID -o value "$HOST_DEV" || true)
[ -n "$HOST_PARTUUID" ] || fail "pas de PARTUUID sur $HOST_DEV (table de partitions MBR ?)"

info "hôte      : $HOST_MNT -> $HOST_DEV ($HOST_FS)"
info "PARTUUID  : $HOST_PARTUUID"

case "$HOST_FS" in
	ntfs|ntfs3) : ;;
	*) echo "    ATTENTION : $HOST_DEV est en '$HOST_FS' et non en NTFS." ;;
esac

LIBRE_MO=$(df -BM --output=avail "$HOST_MNT" | tail -1 | tr -dc '0-9')
BESOIN_MO=$(( SIZE_GB * 1024 + SWAP_GB * 1024 + 512 ))
[ "$LIBRE_MO" -ge "$BESOIN_MO" ] || fail "espace insuffisant sur $HOST_MNT : ${LIBRE_MO} Mo libres, ${BESOIN_MO} Mo requis"
info "espace    : ${LIBRE_MO} Mo libres, ${BESOIN_MO} Mo requis"

if [ -z "$PASSWORD" ]; then
	read -r -s -p "    Mot de passe pour $USERNAME : " PASSWORD; echo
	[ -n "$PASSWORD" ] || fail "mot de passe vide"
fi

if [ "$WITH_BOOTLOADER" = 1 ] && [ -z "$ESP_MNT" ]; then
	for c in /boot/efi /efi /mnt/esp; do
		mountpoint -q "$c" 2>/dev/null && { ESP_MNT="$c"; break; }
	done
	[ -n "$ESP_MNT" ] || fail "partition EFI introuvable — montez-la et passez --esp <point>, ou --no-bootloader"
fi
[ "$WITH_BOOTLOADER" = 1 ] && info "ESP       : $ESP_MNT"

TARGET="$HOST_MNT/$INSTALL_DIR"
ROOTDISK="$TARGET/disks/root.disk"
[ -e "$ROOTDISK" ] && fail "$ROOTDISK existe déjà — désinstallez d'abord ou changez --install-dir"

WORK=$(mktemp -d)
MNT_ISO="$WORK/iso"; MNT_ROOT="$WORK/root"; MNT_LAYERS="$WORK/layers"; MNT_MERGED="$WORK/merged"
mkdir -p "$MNT_ISO" "$MNT_ROOT" "$MNT_LAYERS" "$MNT_MERGED"

cleanup() {
	set +e
	for m in "$MNT_ROOT/dev/pts" "$MNT_ROOT/dev" "$MNT_ROOT/proc" "$MNT_ROOT/sys" \
	         "$MNT_MERGED" "$MNT_LAYERS"/* "$MNT_ROOT" "$MNT_ISO"; do
		mountpoint -q "$m" 2>/dev/null && umount -l "$m"
	done
	rmdir "$WORK"/* "$WORK" 2>/dev/null
	set -e
}
trap cleanup EXIT

# ------------------------------------------------------------------ ISO
say "Lecture de l'ISO"
mount -o ro,loop "$ISO" "$MNT_ISO" || fail "montage de l'ISO impossible"
[ -d "$MNT_ISO/casper" ] || fail "pas de dossier casper dans l'ISO : image Ubuntu attendue"

# Les couches s'empilent : base d'abord, surcouches ensuite. On écarte .live
# (session live) et .installer (installeur), inutiles dans un système installé.
mapfile -t LAYERS < <(
	find "$MNT_ISO/casper" -maxdepth 1 -name '*.squashfs' -printf '%f\n' \
	| grep -v -- '\.live\.' | grep -v -- '\.installer\.' \
	| awk '{ print length"\t"$0 }' | sort -n | cut -f2-
)
[ ${#LAYERS[@]} -gt 0 ] || fail "aucune couche squashfs exploitable dans casper/"
[ -f "$MNT_ISO/.disk/info" ] && info "image     : $(cat "$MNT_ISO/.disk/info")"
for l in "${LAYERS[@]}"; do info "couche    : $l"; done

# ------------------------------------------------------------------ root.disk
say "Création de /$INSTALL_DIR/disks/root.disk (${SIZE_GB} Go)"
mkdir -p "$TARGET/disks"
truncate -s "${SIZE_GB}G" "$ROOTDISK"
mkfs.ext4 -F -q -L wubi-root "$ROOTDISK"
mount -o loop "$ROOTDISK" "$MNT_ROOT" || fail "loop-montage de root.disk impossible"

if [ "$SWAP_GB" -gt 0 ]; then
	info "swap.disk (${SWAP_GB} Go)"
	truncate -s "${SWAP_GB}G" "$TARGET/disks/swap.disk"
	mkswap -q "$TARGET/disks/swap.disk" >/dev/null
fi

say "Déballage du système"
# unsquashfs ne sait pas écraser un lien dur existant ("failed to create
# hardlink"), donc on empile les couches en overlay — comme le fait casper au
# démarrage — puis on recopie la vue fusionnée.
LOWER=""; i=0
for layer in "${LAYERS[@]}"; do
	i=$((i + 1)); LDIR="$MNT_LAYERS/$i"; mkdir -p "$LDIR"
	mount -t squashfs -o ro,loop "$MNT_ISO/casper/$layer" "$LDIR" || fail "montage de $layer"
	LOWER="$LDIR${LOWER:+:$LOWER}"   # overlayfs : la plus à gauche l'emporte
done
mount -t overlay overlay -o "lowerdir=$LOWER" "$MNT_MERGED" || fail "empilement overlay impossible"
info "recopie en cours (plusieurs minutes)..."
rsync -aHAXx --numeric-ids "$MNT_MERGED/" "$MNT_ROOT/"
umount "$MNT_MERGED"
for d in "$MNT_LAYERS"/*; do mountpoint -q "$d" && umount "$d"; done
info "occupé : $(df -h --output=used "$MNT_ROOT" | tail -1 | tr -d ' ')"

# ------------------------------------------------------------------ configuration
say "Configuration du système"
mount --bind /dev "$MNT_ROOT/dev"
mount --bind /dev/pts "$MNT_ROOT/dev/pts"
mount -t proc proc "$MNT_ROOT/proc"
mount -t sysfs sysfs "$MNT_ROOT/sys"

cat > "$MNT_ROOT/etc/fstab" << EOF
# Racine dans un fichier sur la partition Windows, monté en boucle par
# l'initramfs (paramètre loop= de la ligne de commande du noyau).
/host/$INSTALL_DIR/disks/root.disk  /      ext4   loop,errors=remount-ro  0 1
PARTUUID=$HOST_PARTUUID             /host  ntfs3  defaults,nofail,windows_names  0 0
EOF
[ "$SWAP_GB" -gt 0 ] && \
	echo "/host/$INSTALL_DIR/disks/swap.disk  none  swap  loop,sw  0 0" >> "$MNT_ROOT/etc/fstab"

echo "$HOSTNAME_" > "$MNT_ROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME_" > "$MNT_ROOT/etc/hosts"

# Sans ces modules dans l'initramfs, pas de /host, donc pas de root.disk.
mkdir -p "$MNT_ROOT/etc/initramfs-tools"
{ echo ntfs3; echo loop; echo ext4; } >> "$MNT_ROOT/etc/initramfs-tools/modules"

printf 'XKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' \
	"$KEYBOARD" > "$MNT_ROOT/etc/default/keyboard"

cat > "$MNT_ROOT/tmp/config.sh" << CHROOT
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Locale et fuseau, sans réseau : tout est déjà présent dans le squashfs.
sed -i 's/^# *\(${LOCALE}\)/\1/' /etc/locale.gen 2>/dev/null || true
grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
echo "LANG=${LOCALE}" > /etc/default/locale
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone

id -u "${USERNAME}" >/dev/null 2>&1 || \
	useradd -m -s /bin/bash -c "${USERNAME}" "${USERNAME}"
for g in sudo audio video plugdev netdev cdrom dip render; do
	getent group "\$g" >/dev/null && usermod -aG "\$g" "${USERNAME}" || true
done
echo "${USERNAME}:${PASSWORD}" | chpasswd
passwd -l root >/dev/null 2>&1 || true

# Une console série sert au diagnostic si l'affichage ne suit pas.
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true

# Services propres aux images serveur, sans objet ici et qui BLOQUENT le
# demarrage : multipathd (chemins multiples SAN) reste indefiniment en cours de
# demarrage sur une racine loop-montee, et cloud-init attend des sources de
# donnees inexistantes. Neutralises s'ils sont presents.
for s in multipathd.service multipathd.socket; do
	systemctl list-unit-files "\$s" >/dev/null 2>&1 && systemctl mask "\$s" >/dev/null 2>&1 || true
done
if [ -d /etc/cloud ]; then
	touch /etc/cloud/cloud-init.disabled
	echo "    cloud-init desactive"
fi

KVER=\$(ls /lib/modules | sort -V | tail -1)
echo "    noyau : \$KVER"
# 26.04 installe dracut ET initramfs-tools, et dracut est le générateur par
# défaut — or il ne connaît pas loop= et tenterait de monter la NTFS comme
# racine. On force donc initramfs-tools, dont scripts/local gère loop=.
if command -v mkinitramfs >/dev/null 2>&1; then
	mkinitramfs -o "/boot/initrd.img-\$KVER" "\$KVER"
else
	update-initramfs -u -k "\$KVER"
fi
if lsinitramfs "/boot/initrd.img-\$KVER" 2>/dev/null | grep -q "scripts/local"; then
	echo "    initramfs : initramfs-tools (correct)"
else
	echo "    ATTENTION : l'initramfs ne semble pas venir d'initramfs-tools ;"
	echo "                le paramètre loop= risque d'être ignoré au démarrage."
fi
CHROOT
chmod +x "$MNT_ROOT/tmp/config.sh"
chroot "$MNT_ROOT" /tmp/config.sh || fail "configuration en chroot"
rm -f "$MNT_ROOT/tmp/config.sh"

KERNEL=$(cd "$MNT_ROOT/boot" && ls vmlinuz-* | sort -V | tail -1)
INITRD=$(cd "$MNT_ROOT/boot" && ls initrd.img-* | sort -V | tail -1)
[ -n "$KERNEL" ] && [ -n "$INITRD" ] || fail "noyau ou initramfs absent de root.disk"
info "noyau  : $KERNEL"
info "initrd : $INITRD"

CMDLINE="root=PARTUUID=$HOST_PARTUUID rootfstype=ntfs3 loop=/$INSTALL_DIR/disks/root.disk loopfstype=ext4 ro quiet splash"
[ "$CONSOLE_SERIAL" = 1 ] && CMDLINE="$CMDLINE console=ttyS0,115200 console=tty0"

# Menu lu depuis l'intérieur de root.disk. NE PAS y réinitialiser le port série :
# le refaire dans une configuration imbriquée coupe la sortie.
mkdir -p "$MNT_ROOT/boot/grub"
cat > "$MNT_ROOT/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0
menuentry "Ubuntu (Wubi)" {
	linux /boot/$KERNEL $CMDLINE
	initrd /boot/$INITRD
}
menuentry "Ubuntu (Wubi) — mode secours" {
	linux /boot/$KERNEL root=PARTUUID=$HOST_PARTUUID rootfstype=ntfs3 loop=/$INSTALL_DIR/disks/root.disk loopfstype=ext4 ro single console=ttyS0,115200
	initrd /boot/$INITRD
}
EOF

sync
for m in "$MNT_ROOT/dev/pts" "$MNT_ROOT/dev" "$MNT_ROOT/proc" "$MNT_ROOT/sys"; do
	umount -l "$m" 2>/dev/null || true
done
sync
for t in 1 2 3 4 5; do umount "$MNT_ROOT" 2>/dev/null && break; sleep 2; done
mountpoint -q "$MNT_ROOT" && fail "root.disk n'a pas pu être démonté proprement"

# ------------------------------------------------------------------ amorçage
if [ "$WITH_BOOTLOADER" = 1 ]; then
	say "Installation du chargeur d'amorçage"
	EFI_DIR="$ESP_MNT/EFI/wubildr"
	mkdir -p "$EFI_DIR"

	# search --fs-uuid ÉCHOUE sur du NTFS (grub ne retrouve pas le numéro de
	# série du volume). On cherche donc le FICHIER root.disk, ce qui identifie
	# la partition à coup sûr et sans dépendre d'un UUID.
	cat > "$WORK/embed.cfg" << EOF
insmod part_gpt
insmod part_msdos
insmod ntfs
insmod ext2
insmod loopback
search --no-floppy --file --set=hostdev /$INSTALL_DIR/disks/root.disk
if [ -z "\$hostdev" ]; then
	echo "wubildr : root.disk introuvable sur les partitions visibles."
	echo "Vérifiez que Windows est bien arrêté (démarrage rapide désactivé)."
	sleep 30
fi
loopback lo (\$hostdev)/$INSTALL_DIR/disks/root.disk
set root=(lo)
set prefix=(lo)/boot/grub
configfile /boot/grub/grub.cfg
EOF
	grub-mkimage -O x86_64-efi -p "(lo)/boot/grub" -o "$EFI_DIR/grubx64.efi" \
		-c "$WORK/embed.cfg" \
		part_gpt part_msdos ntfs ntfscomp fat ext2 loopback search search_fs_file \
		search_fs_uuid search_label normal linux configfile echo test terminal serial \
		gfxterm all_video video_bochs video_cirrus ls cat halt reboot sleep minicmd \
		|| fail "grub-mkimage a échoué"
	info "chargeur : $EFI_DIR/grubx64.efi"

	# Chemin de repli du firmware, utile quand aucune entrée UEFI n'est posée.
	mkdir -p "$ESP_MNT/EFI/BOOT"
	if [ ! -f "$ESP_MNT/EFI/BOOT/BOOTX64.EFI" ]; then
		cp "$EFI_DIR/grubx64.efi" "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
		info "posé aussi en EFI/BOOT/BOOTX64.EFI (aucun chargeur n'y était)"
	else
		info "EFI/BOOT/BOOTX64.EFI déjà présent — laissé intact"
	fi

	if [ "$EFI_ENTRY" = 1 ]; then
		if command -v efibootmgr >/dev/null 2>&1; then
			ESP_DEV=$(findmnt -n -o SOURCE --target "$ESP_MNT" | head -1)
			ESP_DISK=$(lsblk -no PKNAME "$ESP_DEV" | head -1)
			ESP_PART=$(lsblk -no PARTN "$ESP_DEV" 2>/dev/null | head -1 || echo "")
			[ -n "$ESP_PART" ] || ESP_PART=$(echo "$ESP_DEV" | grep -o '[0-9]*$')
			efibootmgr -c -d "/dev/$ESP_DISK" -p "$ESP_PART" \
				-L "Ubuntu (Wubi)" -l "\\EFI\\wubildr\\grubx64.efi" >/dev/null \
				&& info "entrée UEFI « Ubuntu (Wubi) » ajoutée" \
				|| echo "    entrée UEFI non ajoutée (efibootmgr a échoué)"
		else
			echo "    efibootmgr absent : entrée UEFI non ajoutée"
		fi
	fi
fi

# Le mot de passe du compte y figure en clair : ce fichier n'a aucune raison de
# survivre à l'installation qu'il a servi à faire.
if [ -f "$REPONSES" ]; then
	rm -f "$REPONSES"
	info "réponses effacées (elles contenaient le mot de passe en clair)"
fi

say "TERMINÉ"
cat << FIN
    Système  : $ROOTDISK (${SIZE_GB} Go)
    Compte   : $USERNAME
    Hôte     : $HOST_DEV (PARTUUID=$HOST_PARTUUID)

    Il reste à faire, sous Windows et en administrateur :

      1. Désactiver le démarrage rapide — sans quoi la NTFS reste marquée sale
         et le démarrage échouera :
           powercfg /h off

      2. Déclarer le chargeur, au choix :
           bcdedit /copy {bootmgr} /d "Ubuntu (Wubi)"
         ou, plus simple, relancer ce script avec --efi-entry depuis Linux.

      3. Secure Boot : grubx64.efi n'est pas signé. Soit vous le désactivez le
         temps de l'essai, soit vous le signez et enrôlez la clé via MokManager
         (le Makefile de wubiuefi contient la chaîne shim prévue pour cela).

    Désinstallation : supprimer $TARGET, le dossier EFI/wubildr, et l'entrée UEFI.
FIN
