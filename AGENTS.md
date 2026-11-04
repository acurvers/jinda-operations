# Jinda Operations - publicatieafspraken

- Publiceer alleen na expliciete toestemming van de gebruiker.
- Controleer scripts na publicatie met `tools/Test-PagesPublication.ps1 -ScriptsOnly -CommitSha <volledige SHA>`. Exitcode 0 bewijst de drie directe GitHub-downloads. Scripts zijn onafhankelijk van Pages; wacht daarvoor niet op een Pages-run.
- Controleer een gewijzigde instructiewebpagina apart met `tools/Test-PagesPublication.ps1 -CommitSha <volledige SHA> -TimeoutSeconds 60`. Meld de webpagina pas live bij exitcode 0. Meld bij een wachtrij kort de afzonderlijke script- en webpaginastatus; blijf niet herhaald wachten of builds starten.
- Een commit/push of HTTP 200 alleen is geen publicatiebewijs; de ontvangen bytes moeten bij de exacte commit horen.
- Voer de installatie- of configuratiescripts niet op de beheer-pc uit om de publicatie te testen; gebruik offline tests en de alleen-lezen-publicatiecontrole.
