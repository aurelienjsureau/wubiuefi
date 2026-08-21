<#
.SYNOPSIS
    Étape Windows de l'installation Wubi : prépare le redémarrage vers Ubuntu.

.DESCRIPTION
    Ce script NE fait PAS l'installation. Il prépare seulement le démarrage :

      1. copie l'ISO Ubuntu dans <disque>\ubuntu\
      2. y dépose install-wubi.sh et la configuration de démarrage
      3. installe wubildr (grubx64.efi) sur la partition EFI
      4. ajoute une entrée au menu de démarrage de Windows

    Au redémarrage suivant, choisir cette entrée amène dans une session live
    Ubuntu chargée depuis le disque dur - sans clé USB. C'est là que
    install-wubi.sh installe réellement le système dans root.disk.

    Rien n'est installé sur Windows : PowerShell, bcdedit et mountvol sont
    livrés avec le système. Tout se défait avec -Uninstall.

.PARAMETER Iso
    Chemin de l'ISO Ubuntu (26.04 ou plus récent).

.PARAMETER Wubildr
    Chemin de grubx64.efi, produit par tools/wubi/build-wubildr.sh sous Linux.

.PARAMETER InstallScript
    Chemin de install-wubi.sh (par défaut : à côté de ce script).

.PARAMETER TargetDrive
    Disque hôte, par défaut C:. Doit être en NTFS.

.PARAMETER Uninstall
    Retire l'entrée de démarrage, wubildr et le dossier \ubuntu\.

.EXAMPLE
    .\Install-Wubi.ps1 -Iso D:\ubuntustudio-26.04-desktop-amd64.iso -Wubildr .\grubx64.efi
#>
[CmdletBinding()]
param(
    [string]$Iso,
    [string]$Wubildr,
    [string]$InstallScript,
    [string]$TargetDrive = "C:",
    [switch]$Uninstall,
    [switch]$GarderDemarrageRapide
)

$ErrorActionPreference = 'Stop'

$Journal = "$env:PUBLIC\wubi-install.log"
try { Start-Transcript -Path $Journal -Force | Out-Null } catch { }

function Etape($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Info($m)  { Write-Host "    $m" }
function Souci($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Fatal($m) {
    Write-Host ""
    Write-Host "ECHEC : $m" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

function EntreesWubi {
    $texte = (bcdedit /enum firmware | Out-String)
    $trouvees = @()
    foreach ($bloc in ($texte -split "(?:\r?\n){2,}")) {
        if ($bloc -match 'Ubuntu \(Wubi\)' -and $bloc -match '(?im)^\s*(?:identifier|identificateur)\s+(\{[0-9a-fA-F-]+\})') {
            $trouvees += $Matches[1]
        }
    }
    return $trouvees
}

trap {
    Write-Host ""
    Write-Host "ECHEC INATTENDU : $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

$ICI = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
if (-not $InstallScript) { $InstallScript = Join-Path $ICI 'install-wubi.sh' }

Etape "Verifications"
Info "journal : $Journal"
Info "parametres recus :"
Info "  -Iso           = [$Iso]"
Info "  -Wubildr       = [$Wubildr]"
Info "  -InstallScript = [$InstallScript]"
Info "  -TargetDrive   = [$TargetDrive]"

$moi = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fatal "a lancer dans un PowerShell ADMINISTRATEUR (clic droit sur le menu Demarrer > Terminal (admin))"
}

$firmware = $env:firmware_type
if (-not $firmware) {
    $firmware = if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'Unknown' }
}
if ($firmware -eq 'Legacy') { Fatal "cette machine demarre en mode BIOS/Legacy, or wubildr est un chargeur EFI" }
Info "micrologiciel : $firmware"

$racine = "$TargetDrive\ubuntu"
$dossierInstall = "$racine\install"

if ($Uninstall) {
    Etape "Desinstallation"
    $entrees = @(EntreesWubi)
    foreach ($id in $entrees) {
        bcdedit /delete $id /f | Out-Null
        if ($LASTEXITCODE -eq 0) { Info "entree de demarrage supprimee : $id" }
        else { Souci "suppression impossible, a faire a la main : bcdedit /delete $id /f" }
    }
    if ($entrees.Count -eq 0) { Info "aucune entree Ubuntu (Wubi) dans le menu de demarrage" }
    mountvol S: /s 2>$null
    if (Test-Path 'S:\EFI\wubildr') { Remove-Item 'S:\EFI\wubildr' -Recurse -Force; Info "wubildr retire de l'ESP" }
    mountvol S: /d 2>$null
    if (Test-Path $racine) { Remove-Item $racine -Recurse -Force; Info "$racine supprime" }
    Info "termine."
    exit 0
}

if (-not $Iso)     { Fatal "-Iso est obligatoire" }
if (-not $Wubildr) { Fatal "-Wubildr est obligatoire (produit par build-wubildr.sh sous Linux)" }
foreach ($f in @($Iso, $Wubildr, $InstallScript)) {
    if (-not (Test-Path $f)) { Fatal "fichier introuvable : $f" }
}

$empreinte = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Wubildr))
if (-not $empreinte.Contains('normal (memdisk)/wubildr.cfg')) {
    Souci "Ce fichier .efi ne contient pas sa configuration en mini-disque."
    Souci "grub s'arreterait a son invite sans rien demarrer."
    Souci "Prenez le grubx64.efi livre avec ce script, ou reconstruisez-le"
    Souci "avec tools/wubi/build-wubildr.sh."
    Fatal "chargeur inutilisable (version perimee) : $Wubildr"
}
$version = [regex]::Match($empreinte, 'echo "wubildr ([^"]{1,64})"')
if ($version.Success) { Info "chargeur      : version $($version.Groups[1].Value)" }
else { Souci "chargeur      : version inconnue (image sans marquage)" }

$volume = Get-Volume -DriveLetter $TargetDrive.TrimEnd(':')
if ($volume.FileSystem -ne 'NTFS') { Fatal "$TargetDrive est en $($volume.FileSystem) ; le NTFS est requis" }

$isoInfo = Get-Item $Iso
$besoinGo = [math]::Ceiling($isoInfo.Length / 1GB) + 35
$libreGo  = [math]::Round($volume.SizeRemaining / 1GB, 1)
Info "disque cible  : $TargetDrive ($($volume.FileSystem), $libreGo Go libres)"
Info "ISO           : $($isoInfo.Name) ($([math]::Round($isoInfo.Length/1GB,2)) Go)"
if ($libreGo -lt $besoinGo) { Fatal "espace insuffisant : $libreGo Go libres, ~$besoinGo Go necessaires (ISO + systeme)" }

Etape "Demarrage rapide de Windows"
$cle = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$rapide = (Get-ItemProperty -Path $cle -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
if ($rapide -eq 1) {
    Souci "Le demarrage rapide est ACTIF."
    Souci "Windows ne s'eteint alors jamais vraiment : il s'hiberne, et la partition"
    Souci "NTFS reste marquee comme occupee. Linux ne pourra pas y ecrire, donc le"
    Souci "systeme ne demarrera pas."
    if ($GarderDemarrageRapide) {
        Souci "laisse actif a votre demande : l'installation echouera probablement."
    } else {
        powercfg /h off
        Info "desactive. (Pour le remettre plus tard : powercfg /h on)"
    }
} else {
    Info "deja desactive."
}

Etape "Copie des fichiers sur $TargetDrive"
New-Item -ItemType Directory -Force -Path "$racine\disks", $dossierInstall | Out-Null

$isoCible = "$racine\$($isoInfo.Name)"
if (Test-Path $isoCible) {
    Info "ISO deja presente, copie ignoree"
} else {
    Info "copie de l'ISO (plusieurs minutes)..."
    Copy-Item $Iso $isoCible
}
Copy-Item $InstallScript "$dossierInstall\install-wubi.sh" -Force
Info "install-wubi.sh depose dans $dossierInstall"

$nomIso = $isoInfo.Name
$cfg = @"
search --no-floppy --file --set=hostdev /ubuntu/install/wubi-install.cfg
loopback iso (`$hostdev)/ubuntu/$nomIso
set root=(iso)
set gfxpayload=keep
linux (iso)/casper/vmlinuz iso-scan/filename=/ubuntu/$nomIso --- quiet splash
initrd (iso)/casper/initrd
boot
"@
[IO.File]::WriteAllText("$dossierInstall\wubi-install.cfg", $cfg.Replace("`r`n","`n"))
Info "configuration de demarrage ecrite"

Etape "Installation du chargeur sur la partition EFI"
$lettreEsp = 'S:'
if (Test-Path $lettreEsp) { $lettreEsp = 'Y:' }
mountvol $lettreEsp /s
if (-not (Test-Path $lettreEsp)) { Fatal "impossible de monter la partition EFI" }
try {
    New-Item -ItemType Directory -Force -Path "$lettreEsp\EFI\wubildr" | Out-Null
    Copy-Item $Wubildr "$lettreEsp\EFI\wubildr\grubx64.efi" -Force
    Info "grubx64.efi installe dans \EFI\wubildr\"
} finally {
    mountvol $lettreEsp /d
}

Etape "Entree dans le menu de demarrage"
$entrees = @(EntreesWubi)
if ($entrees.Count -gt 1) {
    foreach ($double in $entrees[1..($entrees.Count - 1)]) {
        bcdedit /delete $double /f | Out-Null
        Info "entree en double supprimee : $double"
    }
}
if ($entrees.Count -ge 1) {
    $id = $entrees[0]
    Info "entree existante reutilisee : $id"
} else {
    $sortie = bcdedit /copy '{bootmgr}' /d 'Ubuntu (Wubi)' 2>&1 | Out-String
    if ($sortie -match '\{[0-9a-fA-F-]{36}\}') { $id = $Matches[0]; Info "entree creee : $id" }
    else { $id = $null }
}
if ($id) {
    bcdedit /set $id path \EFI\wubildr\grubx64.efi | Out-Null
    bcdedit /set '{fwbootmgr}' displayorder $id /addlast | Out-Null
    Info "placee EN DERNIER : Windows reste le systeme par defaut"
} else {
    Souci "creation automatique impossible. A faire a la main :"
    Souci "  bcdedit /copy {bootmgr} /d `"Ubuntu (Wubi)`""
    Souci "  bcdedit /set {identifiant-obtenu} path \EFI\wubildr\grubx64.efi"
    Souci "  bcdedit /set {fwbootmgr} displayorder {identifiant-obtenu} /addlast"
}

Etape "PRET"
Write-Host @"
    Redemarrez en maintenant la touche du MENU DE DEMARRAGE de la carte mere
    (F12, F8, F11 ou Echap selon le modele), puis choisissez " Ubuntu (Wubi) ".

    AUCUN menu ne s'affiche tout seul : l'entree a ete placee en DERNIER pour
    que Windows reste le systeme par defaut. Sans appuyer sur cette touche, la
    machine demarre sous Windows comme d'habitude - c'est voulu.

    Vous arriverez dans une session live Ubuntu, chargee depuis l'ISO posee sur
    $TargetDrive - aucune cle USB necessaire. Ouvrez-y un terminal et lancez :

        sudo bash /media/*/ubuntu/install/install-wubi.sh \
             --iso /media/*/ubuntu/$nomIso \
             --host /media/*/<partition Windows> \
             --size 40 --user <votre-nom> \
             --locale fr_FR.UTF-8 --keyboard fr --timezone Europe/Paris

    (le chemin exact de la partition Windows s'obtient avec : lsblk -f)

    Un dernier redemarrage et Ubuntu demarrera depuis root.disk.

    ATTENTION : grubx64.efi n'est pas signe. Si le Secure Boot est actif, il
    faudra soit le desactiver dans le firmware, soit signer le chargeur et
    enroler la cle via MokManager.

    Pour tout defaire :  .\Install-Wubi.ps1 -Uninstall
"@ -ForegroundColor Green

try { Stop-Transcript | Out-Null } catch { }
exit 0
