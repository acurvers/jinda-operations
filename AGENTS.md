# Jinda Operations - publicatieafspraken

- Publiceer alleen na expliciete toestemming van de gebruiker.
- Controleer na iedere publicatie de exacte commit met `tools/Test-PagesPublication.ps1 -CommitSha <volledige SHA>`. Meld pas succes bij exitcode 0: zowel de Pages-run als de publieke downloads moeten kloppen.
- Een commit/push of HTTP 200 is geen publicatiebewijs. Bij annulering/falen: onderzoek de Pages-run, herstart de benodigde publicatiestap binnen de gegeven toestemming en controleer opnieuw. Meld een resterende blokkade eerlijk.
- Voer de installatie- of configuratiescripts niet op de beheer-pc uit om de publicatie te testen; gebruik offline tests en de alleen-lezen-publicatiecontrole.
