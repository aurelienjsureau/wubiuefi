[CmdletBinding()]
param(
    [string]$Wubildr,
    [string]$Sortie
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ici = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Wubildr) { $Wubildr = Join-Path $ici 'grubx64.efi' }
if (-not $Sortie)  { $Sortie  = Join-Path (Split-Path -Parent (Split-Path -Parent $ici)) 'build\winboot\Wubi.exe' }

$modele    = Join-Path $ici 'Wubi.ps1'
$installSh = Join-Path $ici 'install-wubi.sh'
$source    = Join-Path $ici 'exe\WubiHost.cs'
$manifeste = Join-Path $ici 'exe\Wubi.manifest'

foreach ($f in @($modele, $installSh, $source, $manifeste, $Wubildr)) {
    if (-not (Test-Path $f)) { throw "fichier introuvable : $f" }
}

$octetsWubildr = [IO.File]::ReadAllBytes($Wubildr)
$empreinte = [Text.Encoding]::ASCII.GetString($octetsWubildr)
if (-not $empreinte.Contains('normal (memdisk)/wubildr.cfg')) {
    throw "chargeur perime (marqueur absent) : $Wubildr"
}
$version = [regex]::Match($empreinte, 'echo "wubildr ([^"]{1,64})"')
$versionWubildr = if ($version.Success) { $version.Groups[1].Value } else { 'inconnue' }

$script = [IO.File]::ReadAllText($modele, [Text.Encoding]::UTF8)
$script = $script.Replace('@@WUBILDR@@',   [Convert]::ToBase64String($octetsWubildr))
$script = $script.Replace('@@INSTALLSH@@', [Convert]::ToBase64String([IO.File]::ReadAllBytes($installSh)))
$script = $script.Replace('@@VERSION@@',   $versionWubildr)

$travail = Join-Path ([IO.Path]::GetTempPath()) ("wubi-exe-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $travail | Out-Null
$scriptFusionne = Join-Path $travail 'wubi.ps1'
[IO.File]::WriteAllText($scriptFusionne, $script, (New-Object Text.UTF8Encoding($false)))

$erreurs = $null
[void][Management.Automation.Language.Parser]::ParseFile($scriptFusionne, [ref]$null, [ref]$erreurs)
if ($erreurs -and $erreurs.Count -gt 0) {
    foreach ($e in $erreurs) { Write-Host ("  ligne {0} : {1}" -f $e.Extent.StartLineNumber, $e.Message) }
    throw "le script embarque ne se parse pas ($($erreurs.Count) erreurs)"
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe introuvable : $csc" }

$automation = [psobject].Assembly.Location
$winforms   = [Windows.Forms.Form].Assembly.Location
$drawing    = [Drawing.Point].Assembly.Location

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Sortie) | Out-Null

$arguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$Sortie",
    "/win32manifest:$manifeste",
    "/resource:$scriptFusionne,wubi.ps1",
    "/reference:$automation", '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    $source
)
& $csc @arguments
if ($LASTEXITCODE -ne 0) { throw "compilation echouee (code $LASTEXITCODE)" }

Remove-Item $travail -Recurse -Force

$taille = [math]::Round((Get-Item $Sortie).Length / 1MB, 2)
Write-Host "produit : $Sortie ($taille Mo, chargeur $versionWubildr)"
