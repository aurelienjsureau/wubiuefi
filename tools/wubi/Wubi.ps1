$ErrorActionPreference = 'Stop'

$WubildrB64   = '@@WUBILDR@@'
$InstallShB64 = '@@INSTALLSH@@'
$VersionExe   = '@@VERSION@@'

$Journal = "$env:PUBLIC\wubi-install.log"
$script:Trace = $null

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Journaliser($m) {
    try { Add-Content -Path $Journal -Value $m -Encoding UTF8 } catch { }
    if ($script:Trace) {
        $script:Trace.AppendText($m + "`r`n")
        $script:Trace.SelectionStart = $script:Trace.TextLength
        $script:Trace.ScrollToCaret()
        [Windows.Forms.Application]::DoEvents()
    }
}

function Etape($m) { Journaliser ""; Journaliser "=== $m ===" }
function Info($m)  { Journaliser "    $m" }

function EstAdministrateur {
    $moi = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function OctetsWubildr {
    $octets = [Convert]::FromBase64String($WubildrB64)
    $texte = [Text.Encoding]::ASCII.GetString($octets)
    if (-not $texte.Contains('normal (memdisk)/wubildr.cfg')) {
        throw "le chargeur embarque est inutilisable : configuration en mini-disque absente"
    }
    return $octets
}

function VersionWubildr {
    $texte = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($WubildrB64))
    $m = [regex]::Match($texte, 'echo "wubildr ([^"]{1,64})"')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'inconnue'
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

function AvecEsp([scriptblock]$action) {
    $lettre = 'S:'
    if (Test-Path $lettre) { $lettre = 'Y:' }
    mountvol $lettre /s
    if (-not (Test-Path $lettre)) { throw "impossible de monter la partition EFI" }
    try { & $action $lettre } finally { mountvol $lettre /d }
}

function CopierAvecProgression($source, $cible, $barre, $etat) {
    $lecture = [IO.File]::OpenRead($source)
    $ecriture = [IO.File]::Create($cible)
    try {
        $tampon = [byte[]]::new(4194304)
        $total = $lecture.Length
        $fait = 0
        $dernier = -1
        while (($lu = $lecture.Read($tampon, 0, $tampon.Length)) -gt 0) {
            $ecriture.Write($tampon, 0, $lu)
            $fait += $lu
            $pourcent = [int](100 * $fait / $total)
            if ($pourcent -ne $dernier) {
                $dernier = $pourcent
                if ($barre) { $barre.Value = $pourcent }
                if ($etat)  { $etat.Text = "Copie de l'image ISO : $pourcent %" }
                [Windows.Forms.Application]::DoEvents()
            }
        }
    } finally {
        $lecture.Dispose()
        $ecriture.Dispose()
    }
}

function Preparer($iso, $lettre, $taille, $reponses, $garderRapide, $barre, $etat) {
    Etape "Verifications"
    Info "Wubi $VersionExe"
    Info "chargeur embarque : version $(VersionWubildr)"
    Info "disque cible      : $lettre"

    if (-not (EstAdministrateur)) { throw "droits administrateur manquants" }

    $firmware = $env:firmware_type
    if (-not $firmware) {
        $firmware = if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'Inconnu' }
    }
    if ($firmware -eq 'Legacy') { throw "cette machine demarre en mode BIOS/Legacy, or wubildr est un chargeur EFI" }
    Info "micrologiciel     : $firmware"

    $volume = Get-Volume -DriveLetter $lettre.TrimEnd(':')
    if ($volume.FileSystem -ne 'NTFS') { throw "$lettre est en $($volume.FileSystem) ; le NTFS est requis" }

    $isoInfo = Get-Item $iso
    $besoinGo = [math]::Ceiling($isoInfo.Length / 1GB) + $taille + 2
    $libreGo = [math]::Round($volume.SizeRemaining / 1GB, 1)
    Info "espace libre      : $libreGo Go"
    Info "image             : $($isoInfo.Name) ($([math]::Round($isoInfo.Length / 1GB, 2)) Go)"
    if ($libreGo -lt $besoinGo) {
        throw "espace insuffisant sur $lettre : $libreGo Go libres, ~$besoinGo Go necessaires (image + systeme de $taille Go)"
    }

    Etape "Demarrage rapide de Windows"
    $cle = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $rapide = (Get-ItemProperty -Path $cle -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($rapide -eq 1) {
        if ($garderRapide) {
            Info "ACTIF, laisse en place a votre demande : l'installation echouera probablement"
        } else {
            powercfg /h off
            Info "desactive (pour le remettre plus tard : powercfg /h on)"
        }
    } else {
        Info "deja desactive"
    }

    Etape "Copie des fichiers sur $lettre"
    $racine = "$lettre\ubuntu"
    $dossierInstall = "$racine\install"
    New-Item -ItemType Directory -Force -Path "$racine\disks", $dossierInstall | Out-Null

    $isoCible = "$racine\$($isoInfo.Name)"
    if ((Test-Path $isoCible) -and ((Get-Item $isoCible).Length -eq $isoInfo.Length)) {
        Info "image deja presente, copie ignoree"
    } elseif ($isoInfo.FullName -eq $isoCible) {
        Info "image deja en place"
    } else {
        if ($etat) { $etat.Text = "Copie de l'image ISO : 0 %" }
        CopierAvecProgression $isoInfo.FullName $isoCible $barre $etat
        Info "image copiee dans $racine"
    }
    if ($barre) { $barre.Value = 100 }
    if ($etat) { $etat.Text = "Installation du chargeur..." }

    [IO.File]::WriteAllBytes("$dossierInstall\install-wubi.sh",
        [Convert]::FromBase64String($InstallShB64))
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
    [IO.File]::WriteAllText("$dossierInstall\wubi-install.cfg", $cfg.Replace("`r`n", "`n"))
    Info "configuration de demarrage ecrite"

    ($reponses.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n" |
        Set-Content -Path "$dossierInstall\wubi-reponses.conf" -Encoding ASCII
    Info "reponses de l'installation ecrites"

    Etape "Installation du chargeur sur la partition EFI"
    $octets = OctetsWubildr
    AvecEsp {
        param($esp)
        New-Item -ItemType Directory -Force -Path "$esp\EFI\wubildr" | Out-Null
        [IO.File]::WriteAllBytes("$esp\EFI\wubildr\grubx64.efi", $octets)
    }
    Info "grubx64.efi installe dans \EFI\wubildr\"

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
        else { throw "impossible de creer l'entree de demarrage : $sortie" }
    }
    bcdedit /set $id path \EFI\wubildr\grubx64.efi | Out-Null
    bcdedit /set '{fwbootmgr}' displayorder $id /addlast | Out-Null
    Info "placee en dernier : Windows reste le systeme par defaut"

    Etape "PRET"
    Info "redemarrer, puis choisir Ubuntu (Wubi) dans le menu de la carte mere"
    if ($etat) { $etat.Text = "Preparation terminee." }
}

function Desinstaller {
    Etape "Desinstallation"
    if (-not (EstAdministrateur)) { throw "droits administrateur manquants" }
    $entrees = @(EntreesWubi)
    foreach ($id in $entrees) {
        bcdedit /delete $id /f | Out-Null
        Info "entree de demarrage supprimee : $id"
    }
    if ($entrees.Count -eq 0) { Info "aucune entree Ubuntu (Wubi) dans le menu de demarrage" }
    AvecEsp {
        param($esp)
        if (Test-Path "$esp\EFI\wubildr") {
            Remove-Item "$esp\EFI\wubildr" -Recurse -Force
            Info "wubildr retire de la partition EFI"
        }
    }
    foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })) {
        $racine = "$($v.DriveLetter):\ubuntu"
        if (Test-Path $racine) {
            Remove-Item $racine -Recurse -Force
            Info "$racine supprime"
        }
    }
    Info "termine"
}

function Interface {
    $f = New-Object Windows.Forms.Form
    $f.Text = "Installation d'Ubuntu aux côtés de Windows"
    $f.Size = New-Object Drawing.Size(640, 580)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false

    $panSaisie = New-Object Windows.Forms.Panel
    $panSaisie.Dock = 'Fill'
    $f.Controls.Add($panSaisie)

    function Etiquette($texte, $y) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $texte
        $l.Location = New-Object Drawing.Point(20, $y)
        $l.Size = New-Object Drawing.Size(180, 22)
        $panSaisie.Controls.Add($l)
    }

    $titre = New-Object Windows.Forms.Label
    $titre.Text = "Ubuntu sera installé dans un fichier sur votre disque Windows.`nAucune partition n'est modifiée, et tout se désinstalle."
    $titre.Location = New-Object Drawing.Point(20, 15)
    $titre.Size = New-Object Drawing.Size(590, 40)
    $panSaisie.Controls.Add($titre)

    Etiquette "Image ISO d'Ubuntu :" 70
    $tIso = New-Object Windows.Forms.TextBox
    $tIso.Location = New-Object Drawing.Point(200, 68)
    $tIso.Size = New-Object Drawing.Size(320, 22)
    $panSaisie.Controls.Add($tIso)
    $bIso = New-Object Windows.Forms.Button
    $bIso.Text = "Parcourir..."
    $bIso.Location = New-Object Drawing.Point(530, 66)
    $bIso.Size = New-Object Drawing.Size(80, 26)
    $bIso.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog
        $d.Filter = "Images ISO (*.iso)|*.iso"
        if ($d.ShowDialog() -eq 'OK') { $tIso.Text = $d.FileName }
    })
    $panSaisie.Controls.Add($bIso)

    Etiquette "Disque d'installation :" 110
    $cDisque = New-Object Windows.Forms.ComboBox
    $cDisque.Location = New-Object Drawing.Point(200, 108)
    $cDisque.Size = New-Object Drawing.Size(410, 22)
    $cDisque.DropDownStyle = 'DropDownList'
    Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' -and $_.SizeRemaining -gt 30GB } |
        Sort-Object DriveLetter | ForEach-Object {
            $cDisque.Items.Add(("{0}: - {1} Go libres{2}" -f $_.DriveLetter,
                [math]::Round($_.SizeRemaining / 1GB, 0),
                $(if ($_.FileSystemLabel) { " ($($_.FileSystemLabel))" } else { "" }))) | Out-Null
        }
    if ($cDisque.Items.Count -gt 0) { $cDisque.SelectedIndex = 0 }
    $panSaisie.Controls.Add($cDisque)

    Etiquette "Taille du système :" 150
    $cTaille = New-Object Windows.Forms.ComboBox
    $cTaille.Location = New-Object Drawing.Point(200, 148)
    $cTaille.Size = New-Object Drawing.Size(150, 22)
    $cTaille.DropDownStyle = 'DropDownList'
    @(20, 30, 40, 60, 80, 120, 200) | ForEach-Object { $cTaille.Items.Add("$_ Go") | Out-Null }
    $cTaille.SelectedIndex = 2
    $panSaisie.Controls.Add($cTaille)

    Etiquette "Nom d'utilisateur :" 190
    $tUser = New-Object Windows.Forms.TextBox
    $tUser.Location = New-Object Drawing.Point(200, 188)
    $tUser.Size = New-Object Drawing.Size(150, 22)
    $tUser.Text = $env:USERNAME.ToLower() -replace '[^a-z0-9]', ''
    $panSaisie.Controls.Add($tUser)

    Etiquette "Mot de passe :" 230
    $tPass = New-Object Windows.Forms.TextBox
    $tPass.Location = New-Object Drawing.Point(200, 228)
    $tPass.Size = New-Object Drawing.Size(150, 22)
    $tPass.UseSystemPasswordChar = $true
    $panSaisie.Controls.Add($tPass)

    Etiquette "Confirmation :" 270
    $tPass2 = New-Object Windows.Forms.TextBox
    $tPass2.Location = New-Object Drawing.Point(200, 268)
    $tPass2.Size = New-Object Drawing.Size(150, 22)
    $tPass2.UseSystemPasswordChar = $true
    $panSaisie.Controls.Add($tPass2)

    Etiquette "Langue :" 310
    $cLangue = New-Object Windows.Forms.ComboBox
    $cLangue.Location = New-Object Drawing.Point(200, 308)
    $cLangue.Size = New-Object Drawing.Size(150, 22)
    $cLangue.DropDownStyle = 'DropDownList'
    @('fr_FR.UTF-8', 'en_US.UTF-8', 'de_DE.UTF-8', 'es_ES.UTF-8', 'it_IT.UTF-8') |
        ForEach-Object { $cLangue.Items.Add($_) | Out-Null }
    $cLangue.SelectedIndex = 0
    $panSaisie.Controls.Add($cLangue)

    Etiquette "Clavier :" 350
    $cClavier = New-Object Windows.Forms.ComboBox
    $cClavier.Location = New-Object Drawing.Point(200, 348)
    $cClavier.Size = New-Object Drawing.Size(150, 22)
    $cClavier.DropDownStyle = 'DropDownList'
    @('fr', 'us', 'de', 'es', 'it', 'be', 'ch') | ForEach-Object { $cClavier.Items.Add($_) | Out-Null }
    $cClavier.SelectedIndex = 0
    $panSaisie.Controls.Add($cClavier)

    $cRapide = New-Object Windows.Forms.CheckBox
    $cRapide.Text = "Désactiver le démarrage rapide de Windows (nécessaire)"
    $cRapide.Location = New-Object Drawing.Point(20, 390)
    $cRapide.Size = New-Object Drawing.Size(590, 24)
    $cRapide.Checked = $true
    $panSaisie.Controls.Add($cRapide)

    $avert = New-Object Windows.Forms.Label
    $avert.Text = "Sans cela, Windows s'hiberne au lieu de s'éteindre : la partition reste occupée et Ubuntu ne démarrera pas."
    $avert.Location = New-Object Drawing.Point(40, 414)
    $avert.Size = New-Object Drawing.Size(580, 20)
    $avert.ForeColor = [Drawing.Color]::DimGray
    $panSaisie.Controls.Add($avert)

    $pied = New-Object Windows.Forms.Label
    $pied.Text = "Chargeur embarqué : version $(VersionWubildr)"
    $pied.Location = New-Object Drawing.Point(20, 450)
    $pied.Size = New-Object Drawing.Size(400, 20)
    $pied.ForeColor = [Drawing.Color]::DimGray
    $panSaisie.Controls.Add($pied)

    $bDesinst = New-Object Windows.Forms.Button
    $bDesinst.Text = "Tout désinstaller"
    $bDesinst.Location = New-Object Drawing.Point(20, 490)
    $bDesinst.Size = New-Object Drawing.Size(140, 32)
    $panSaisie.Controls.Add($bDesinst)

    $bOk = New-Object Windows.Forms.Button
    $bOk.Text = "Préparer l'installation"
    $bOk.Location = New-Object Drawing.Point(340, 490)
    $bOk.Size = New-Object Drawing.Size(160, 32)
    $panSaisie.Controls.Add($bOk)

    $bAnn = New-Object Windows.Forms.Button
    $bAnn.Text = "Annuler"
    $bAnn.Location = New-Object Drawing.Point(510, 490)
    $bAnn.Size = New-Object Drawing.Size(100, 32)
    $bAnn.Add_Click({ $f.Close() })
    $panSaisie.Controls.Add($bAnn)

    $panTravail = New-Object Windows.Forms.Panel
    $panTravail.Dock = 'Fill'
    $panTravail.Visible = $false
    $f.Controls.Add($panTravail)

    $etat = New-Object Windows.Forms.Label
    $etat.Text = "Préparation..."
    $etat.Location = New-Object Drawing.Point(20, 20)
    $etat.Size = New-Object Drawing.Size(590, 22)
    $panTravail.Controls.Add($etat)

    $barre = New-Object Windows.Forms.ProgressBar
    $barre.Location = New-Object Drawing.Point(20, 48)
    $barre.Size = New-Object Drawing.Size(590, 22)
    $panTravail.Controls.Add($barre)

    $script:Trace = New-Object Windows.Forms.TextBox
    $script:Trace.Location = New-Object Drawing.Point(20, 82)
    $script:Trace.Size = New-Object Drawing.Size(590, 400)
    $script:Trace.Multiline = $true
    $script:Trace.ReadOnly = $true
    $script:Trace.ScrollBars = 'Vertical'
    $script:Trace.Font = New-Object Drawing.Font("Consolas", 8.5)
    $panTravail.Controls.Add($script:Trace)

    $bFermer = New-Object Windows.Forms.Button
    $bFermer.Text = "Fermer"
    $bFermer.Location = New-Object Drawing.Point(510, 490)
    $bFermer.Size = New-Object Drawing.Size(100, 32)
    $bFermer.Enabled = $false
    $bFermer.Add_Click({ $f.Close() })
    $panTravail.Controls.Add($bFermer)

    $bDesinst.Add_Click({
        $q = [Windows.Forms.MessageBox]::Show(
            "Retirer l'entrée de démarrage, le chargeur et le dossier \ubuntu\ de tous les disques ?`n`nWindows n'est pas touché.",
            "Désinstaller", 'OKCancel', 'Warning')
        if ($q -ne 'OK') { return }
        $panSaisie.Visible = $false
        $panTravail.Visible = $true
        $etat.Text = "Désinstallation..."
        try {
            Desinstaller
            $etat.Text = "Désinstallation terminée."
        } catch {
            Journaliser "ECHEC : $_"
            $etat.Text = "Échec de la désinstallation."
        }
        $bFermer.Enabled = $true
    })

    $bOk.Add_Click({
        if (-not (Test-Path $tIso.Text)) { [Windows.Forms.MessageBox]::Show("Choisissez une image ISO.", "Manque") | Out-Null; return }
        if ($cDisque.SelectedItem -eq $null) { [Windows.Forms.MessageBox]::Show("Aucun disque NTFS avec assez d'espace libre.", "Manque") | Out-Null; return }
        if ($tPass.Text -eq '') { [Windows.Forms.MessageBox]::Show("Saisissez un mot de passe.", "Manque") | Out-Null; return }
        if ($tPass.Text -ne $tPass2.Text) { [Windows.Forms.MessageBox]::Show("Les deux mots de passe diffèrent.", "Erreur") | Out-Null; return }
        if ($tUser.Text -notmatch '^[a-z_][a-z0-9_-]*$') { [Windows.Forms.MessageBox]::Show("Nom d'utilisateur invalide : minuscules, chiffres, tiret et souligné.", "Erreur") | Out-Null; return }

        $lettre = ($cDisque.SelectedItem -split ':')[0] + ':'
        $taille = [int](($cTaille.SelectedItem -split ' ')[0])

        $recap = @"
Image      : $(Split-Path $tIso.Text -Leaf)
Disque     : $lettre
Taille     : $taille Go
Compte     : $($tUser.Text)
Langue     : $($cLangue.SelectedItem)   Clavier : $($cClavier.SelectedItem)

Cette étape ne fait que préparer le redémarrage : copie de l'image,
installation du chargeur et ajout d'une entrée au menu de démarrage.
L'installation elle-même se fera après redémarrage.

Continuer ?
"@
        if ([Windows.Forms.MessageBox]::Show($recap, "Confirmation", 'OKCancel', 'Question') -ne 'OK') { return }

        if (Test-Path $Journal) { Remove-Item $Journal -Force -ErrorAction SilentlyContinue }

        $reponses = @{
            user = $tUser.Text; password = $tPass.Text; size = $taille
            locale = $cLangue.SelectedItem; keyboard = $cClavier.SelectedItem
            drive = $lettre
        }

        $panSaisie.Visible = $false
        $panTravail.Visible = $true
        [Windows.Forms.Application]::DoEvents()

        try {
            Preparer $tIso.Text $lettre $taille $reponses (-not $cRapide.Checked) $barre $etat
            $bFermer.Enabled = $true
            [Windows.Forms.MessageBox]::Show(
                "Préparation terminée.`n`nRedémarrez en maintenant la touche du menu de démarrage de votre carte mère (F12, F8, F11 ou Échap), puis choisissez « Ubuntu (Wubi) ».`n`nAucun menu ne s'affiche tout seul : Windows reste le système par défaut.",
                "Terminé") | Out-Null
        } catch {
            Journaliser ""
            Journaliser "ECHEC : $_"
            $etat.Text = "Échec. Rien n'a été installé."
            $barre.Value = 0
            $bFermer.Enabled = $true
            [Windows.Forms.MessageBox]::Show(
                "La préparation a échoué :`n`n$_`n`nLe détail est dans la fenêtre et dans $Journal",
                "Échec", 'OK', 'Error') | Out-Null
        }
    })

    [void]$f.ShowDialog()
}

if (-not (EstAdministrateur)) {
    [Windows.Forms.MessageBox]::Show(
        "Wubi doit être lancé en tant qu'administrateur : il écrit sur la partition EFI et modifie le menu de démarrage.",
        "Droits insuffisants", 'OK', 'Error') | Out-Null
    exit 1
}

Interface
