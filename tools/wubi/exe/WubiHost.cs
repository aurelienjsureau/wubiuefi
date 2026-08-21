// Hôte du script Wubi : un exécutable Windows autonome qui embarque
// tools/wubi/Wubi.ps1 (lui-même porteur de grubx64.efi et install-wubi.sh en
// base64) et le fait tourner DANS son propre processus.
//
// Pourquoi un hôte plutôt qu'un simple raccourci vers powershell.exe :
//
//   - plus de stratégie d'exécution à contourner, plus de fenêtre de console
//     qui clignote, plus de fichier .ps1 à côté de l'exe ;
//   - le script tourne en un seul processus déjà élevé (le manifeste demande
//     les droits administrateur), ce qui supprime d'un coup les deux pièges
//     qui ont coûté deux essais : $PSScriptRoot vide dans un bloc param()
//     évalué sous « powershell -File », et l'élévation par Start-Process dont
//     personne ne lisait le code de sortie ;
//   - le script est chargé depuis les ressources de l'assemblage, donc lu en
//     UTF-8 quoi qu'il arrive : le piège de PowerShell 5.1 qui lit les .ps1 en
//     ANSI quand il n'y a pas de BOM ne s'applique plus.
//
// WinForms exige un fil STA : d'où [STAThread] et ApartmentState.STA sur le
// runspace, avec UseCurrentThread pour que le script s'exécute sur ce fil-là.

using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class WubiHost
{
    [STAThread]
    public static int Main(string[] args)
    {
        string script;
        try
        {
            using (Stream flux = Assembly.GetExecutingAssembly().GetManifestResourceStream("wubi.ps1"))
            using (StreamReader lecteur = new StreamReader(flux, new UTF8Encoding(false)))
            {
                script = lecteur.ReadToEnd();
            }
        }
        catch (Exception e)
        {
            Echec("Le script embarqué est illisible.", e.ToString());
            return 1;
        }

        try
        {
            InitialSessionState etat = InitialSessionState.CreateDefault();
            etat.ApartmentState = ApartmentState.STA;
            etat.ThreadOptions = PSThreadOptions.UseCurrentThread;

            using (Runspace runspace = RunspaceFactory.CreateRunspace(etat))
            {
                runspace.Open();
                using (PowerShell moteur = PowerShell.Create())
                {
                    moteur.Runspace = runspace;
                    moteur.AddScript(script);
                    moteur.Invoke();

                    if (moteur.Streams.Error.Count > 0)
                    {
                        StringBuilder details = new StringBuilder();
                        Collection<ErrorRecord> erreurs = moteur.Streams.Error.ReadAll();
                        foreach (ErrorRecord erreur in erreurs)
                        {
                            details.AppendLine(erreur.ToString());
                        }
                        Echec("Wubi s'est arrêté sur une erreur.", details.ToString());
                        return 1;
                    }
                }
            }
        }
        catch (Exception e)
        {
            Echec("Wubi n'a pas pu démarrer.", e.ToString());
            return 1;
        }

        return 0;
    }

    // Sans console, une exception non rattrapée serait invisible : l'utilisateur
    // verrait l'exe se fermer sans rien dire. Tout échec passe donc par ici.
    private static void Echec(string resume, string details)
    {
        string journal = Path.Combine(
            Environment.GetEnvironmentVariable("PUBLIC") ?? Path.GetTempPath(), "wubi-install.log");
        try
        {
            File.AppendAllText(journal, Environment.NewLine + resume + Environment.NewLine + details);
        }
        catch { }

        MessageBox.Show(
            resume + Environment.NewLine + Environment.NewLine + details +
            Environment.NewLine + Environment.NewLine + "Journal : " + journal,
            "Wubi", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
