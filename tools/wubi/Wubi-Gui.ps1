<#
.SYNOPSIS
    Interface graphique de l'étape Windows de Wubi.

.DESCRIPTION
    Fenêtre WinForms proposant le choix de l'ISO, du disque hôte, de la taille
    du système et du compte à créer, puis appelant Install-Wubi.ps1.

    Repose uniquement sur ce que Windows fournit : rien à installer sur les
    machines cibles. Pour obtenir un exécutable double-cliquable :
        Install-Module ps2exe -Scope CurrentUser
        Invoke-PS2EXE .\Wubi-Gui.ps1 .\Wubi.exe -requireAdmin -noConsole

    Se relance seule en administrateur si nécessaire.
#>
[CmdletBinding()]
param([switch]$Eleve)

# ------------------------------------------------------------ élévation
$moi = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Eleve) { throw "elevation impossible" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Eleve'
    )
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$ICI = Split-Path -Parent $PSCommandPath

# ------------------------------------------------------------ fenêtre
$f = New-Object Windows.Forms.Form
$f.Text = "Installation d'Ubuntu aux côtés de Windows"
$f.Size = New-Object Drawing.Size(640, 560)
$f.StartPosition = 'CenterScreen'
$f.FormBorderStyle = 'FixedDialog'
$f.MaximizeBox = $false

function Etiquette($texte, $y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $texte; $l.Location = New-Object Drawing.Point(20, $y)
    $l.Size = New-Object Drawing.Size(180, 22)
    $f.Controls.Add($l); return $l
}

$titre = New-Object Windows.Forms.Label
$titre.Text = "Ubuntu sera installé dans un fichier sur votre disque Windows.`nAucune partition n'est modifiée, et tout se désinstalle."
$titre.Location = New-Object Drawing.Point(20, 15)
$titre.Size = New-Object Drawing.Size(590, 40)
$f.Controls.Add($titre)

# --- ISO
Etiquette "Image ISO d'Ubuntu :" 70 | Out-Null
$tIso = New-Object Windows.Forms.TextBox
$tIso.Location = New-Object Drawing.Point(200, 68)
$tIso.Size = New-Object Drawing.Size(320, 22)
$f.Controls.Add($tIso)
$bIso = New-Object Windows.Forms.Button
$bIso.Text = "Parcourir..."; $bIso.Location = New-Object Drawing.Point(530, 66)
$bIso.Size = New-Object Drawing.Size(80, 26)
$bIso.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = "Images ISO (*.iso)|*.iso"
    if ($d.ShowDialog() -eq 'OK') { $tIso.Text = $d.FileName }
})
$f.Controls.Add($bIso)

# --- chargeur
Etiquette "Chargeur (grubx64.efi) :" 105 | Out-Null
$tGrub = New-Object Windows.Forms.TextBox
$tGrub.Location = New-Object Drawing.Point(200, 103)
$tGrub.Size = New-Object Drawing.Size(320, 22)
if (Test-Path "$ICI\grubx64.efi") { $tGrub.Text = "$ICI\grubx64.efi" }
$f.Controls.Add($tGrub)
$bGrub = New-Object Windows.Forms.Button
$bGrub.Text = "Parcourir..."; $bGrub.Location = New-Object Drawing.Point(530, 101)
$bGrub.Size = New-Object Drawing.Size(80, 26)
$bGrub.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = "Chargeur EFI (*.efi)|*.efi"
    if ($d.ShowDialog() -eq 'OK') { $tGrub.Text = $d.FileName }
})
$f.Controls.Add($bGrub)

# --- disque : seuls les volumes NTFS avec assez de place
Etiquette "Disque d'installation :" 145 | Out-Null
$cDisque = New-Object Windows.Forms.ComboBox
$cDisque.Location = New-Object Drawing.Point(200, 143)
$cDisque.Size = New-Object Drawing.Size(410, 22)
$cDisque.DropDownStyle = 'DropDownList'
Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' -and $_.SizeRemaining -gt 40GB } |
    Sort-Object DriveLetter | ForEach-Object {
        $cDisque.Items.Add(("{0}: — {1} Go libres{2}" -f $_.DriveLetter,
            [math]::Round($_.SizeRemaining/1GB,0),
            $(if ($_.FileSystemLabel) { " ($($_.FileSystemLabel))" } else { "" }))) | Out-Null
    }
if ($cDisque.Items.Count -gt 0) { $cDisque.SelectedIndex = 0 }
$f.Controls.Add($cDisque)

# --- taille
Etiquette "Taille du système :" 185 | Out-Null
$cTaille = New-Object Windows.Forms.ComboBox
$cTaille.Location = New-Object Drawing.Point(200, 183)
$cTaille.Size = New-Object Drawing.Size(150, 22)
$cTaille.DropDownStyle = 'DropDownList'
@(20,30,40,60,80,120,200) | ForEach-Object { $cTaille.Items.Add("$_ Go") | Out-Null }
$cTaille.SelectedIndex = 2
$f.Controls.Add($cTaille)

# --- compte
Etiquette "Nom d'utilisateur :" 225 | Out-Null
$tUser = New-Object Windows.Forms.TextBox
$tUser.Location = New-Object Drawing.Point(200, 223)
$tUser.Size = New-Object Drawing.Size(150, 22)
$tUser.Text = $env:USERNAME.ToLower() -replace '[^a-z0-9]',''
$f.Controls.Add($tUser)

Etiquette "Mot de passe :" 265 | Out-Null
$tPass = New-Object Windows.Forms.TextBox
$tPass.Location = New-Object Drawing.Point(200, 263)
$tPass.Size = New-Object Drawing.Size(150, 22)
$tPass.UseSystemPasswordChar = $true
$f.Controls.Add($tPass)

Etiquette "Confirmation :" 305 | Out-Null
$tPass2 = New-Object Windows.Forms.TextBox
$tPass2.Location = New-Object Drawing.Point(200, 303)
$tPass2.Size = New-Object Drawing.Size(150, 22)
$tPass2.UseSystemPasswordChar = $true
$f.Controls.Add($tPass2)

# --- langue et clavier
Etiquette "Langue :" 345 | Out-Null
$cLangue = New-Object Windows.Forms.ComboBox
$cLangue.Location = New-Object Drawing.Point(200, 343)
$cLangue.Size = New-Object Drawing.Size(150, 22)
$cLangue.DropDownStyle = 'DropDownList'
@('fr_FR.UTF-8','en_US.UTF-8','de_DE.UTF-8','es_ES.UTF-8','it_IT.UTF-8') |
    ForEach-Object { $cLangue.Items.Add($_) | Out-Null }
$cLangue.SelectedIndex = 0
$f.Controls.Add($cLangue)

Etiquette "Clavier :" 385 | Out-Null
$cClavier = New-Object Windows.Forms.ComboBox
$cClavier.Location = New-Object Drawing.Point(200, 383)
$cClavier.Size = New-Object Drawing.Size(150, 22)
$cClavier.DropDownStyle = 'DropDownList'
@('fr','us','de','es','it','be','ch') | ForEach-Object { $cClavier.Items.Add($_) | Out-Null }
$cClavier.SelectedIndex = 0
$f.Controls.Add($cClavier)

# --- démarrage rapide
$cRapide = New-Object Windows.Forms.CheckBox
$cRapide.Text = "Désactiver le démarrage rapide de Windows (nécessaire)"
$cRapide.Location = New-Object Drawing.Point(20, 420)
$cRapide.Size = New-Object Drawing.Size(590, 24)
$cRapide.Checked = $true
$f.Controls.Add($cRapide)

$avert = New-Object Windows.Forms.Label
$avert.Text = "Sans cela, Windows s'hiberne au lieu de s'éteindre : la partition reste occupée et Ubuntu ne démarrera pas."
$avert.Location = New-Object Drawing.Point(40, 444)
$avert.Size = New-Object Drawing.Size(580, 20)
$avert.ForeColor = [Drawing.Color]::DimGray
$f.Controls.Add($avert)

# --- boutons
$bOk = New-Object Windows.Forms.Button
$bOk.Text = "Préparer l'installation"; $bOk.Location = New-Object Drawing.Point(340, 480)
$bOk.Size = New-Object Drawing.Size(160, 32)
$f.Controls.Add($bOk)

$bAnn = New-Object Windows.Forms.Button
$bAnn.Text = "Annuler"; $bAnn.Location = New-Object Drawing.Point(510, 480)
$bAnn.Size = New-Object Drawing.Size(100, 32)
$bAnn.Add_Click({ $f.Close() })
$f.Controls.Add($bAnn)

$bOk.Add_Click({
    if (-not (Test-Path $tIso.Text))  { [Windows.Forms.MessageBox]::Show("Choisissez une image ISO.","Manque"); return }
    if (-not (Test-Path $tGrub.Text)) { [Windows.Forms.MessageBox]::Show("Choisissez le chargeur grubx64.efi.`n`nIl se télécharge depuis les artefacts du dépôt.","Manque"); return }
    if ($cDisque.SelectedItem -eq $null) { [Windows.Forms.MessageBox]::Show("Aucun disque NTFS avec au moins 40 Go libres.","Manque"); return }
    if ($tPass.Text -eq '')           { [Windows.Forms.MessageBox]::Show("Saisissez un mot de passe.","Manque"); return }
    if ($tPass.Text -ne $tPass2.Text) { [Windows.Forms.MessageBox]::Show("Les deux mots de passe diffèrent.","Erreur"); return }
    if ($tUser.Text -notmatch '^[a-z_][a-z0-9_-]*$') { [Windows.Forms.MessageBox]::Show("Nom d'utilisateur invalide : minuscules, chiffres, tiret et souligné.","Erreur"); return }

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
    if ([Windows.Forms.MessageBox]::Show($recap,"Confirmation",'OKCancel','Question') -ne 'OK') { return }

    $f.Hide()
    $args = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ICI\Install-Wubi.ps1`"",
        '-Iso',"`"$($tIso.Text)`"", '-Wubildr',"`"$($tGrub.Text)`"", '-TargetDrive',$lettre
    )
    # Les choix de compte et de langue servent à la seconde étape : on les
    # dépose à côté du script d'installation, qui les relira dans la session live.
    $reponses = @{
        user = $tUser.Text; password = $tPass.Text; size = $taille
        locale = $cLangue.SelectedItem; keyboard = $cClavier.SelectedItem
        drive = $lettre
    }
    New-Item -ItemType Directory -Force -Path "$lettre\ubuntu\install" | Out-Null
    ($reponses.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n" |
        Set-Content -Path "$lettre\ubuntu\install\wubi-reponses.conf" -Encoding ASCII

    if (-not $cRapide.Checked) { $args += '-GarderDemarrageRapide' }
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $args
    [Windows.Forms.MessageBox]::Show("Préparation terminée.`n`nRedémarrez et choisissez « Ubuntu (Wubi) » au démarrage.","Terminé")
    $f.Close()
})

[void]$f.ShowDialog()
