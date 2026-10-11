# Jinda Operations

Twee vaste scripts voor Windows 11 Pro. Nieuwe software voegen we toe aan
[install-software.ps1](install-software.ps1); nieuwe instellingen aan
[set-windows-english.ps1](set-windows-english.ps1).

De [instructiepagina](https://acurvers.github.io/jinda-operations/) bevat het
kopieerbare codeblok om beide scripts direct achter elkaar uit te voeren.

## Uitvoering

Beide scripts vragen automatisch administratorrechten via Windows UAC en
kiezen de nieuwste aanwezige stabiele PowerShell 7 of hoger voor de native
64-bits architectuur. Ze zoeken in de standaard PowerShell-installatiemappen,
de huidige runtime, PATH en Microsoft Store-installaties. Previewversies
en 32-bits runtimes worden overgeslagen. Zonder geschikte PowerShell 7
starten ze in Windows PowerShell 5.1.

De installatie voegt de nieuwste stabiele PowerShell toe. Het configuratiescript
zoekt daarna opnieuw naar de nieuwste aanwezige versie. Er wordt geen
uitvoeringsbeleid permanent gewijzigd.

De taalcmdlets gebruiken intern een verhoogd Windows PowerShell 5.1-proces
van hetzelfde configuratiebestand. Zo blijven de getypeerde Windows-taalobjecten
beschikbaar zonder deserialisatie via de PowerShell-compatibiliteitslaag.
Er is geen extra configuratiescript nodig.

Start je het codeblok al in een administratorvenster, dan volgt geen extra UAC-vraag.
Anders kan Windows voor elk script om toestemming vragen. Het vervolg wacht
op afronding en stopt bij een fout. Accepteer de UAC-vragen; zonder toestemming
kunnen de scripts geen beheerrechten verkrijgen.

## Software

| Pakket | Gedrag |
| --- | --- |
| Google.Chrome | Installeert voor alle gebruikers; bestaande installatie wordt overgeslagen. |
| TeamViewer.TeamViewer | Volledige EXE-client via nullsoft; bestaande installatie wordt overgeslagen. |
| Microsoft.PowerShell | Nieuwste stabiele versie via de machinebrede MSI (wix); oudere versie wordt bijgewerkt. |

WinGet moet beschikbaar zijn via Microsoft App Installer. De pakket- en
bronvoorwaarden worden automatisch geaccepteerd. De scripts starten geen
remote TeamViewer-sessie en koppelen geen TeamViewer-account.

## Configuratie

Stelt Engels (VS) in voor de systeemvoorkeur, het aanmeldscherm, systeemaccounts,
nieuwe gebruikers en het uitvoerende account. Installeert zo nodig het volledige
en-US-weergavetaalpakket, zonder optionele spraak/OCR-functies. Stelt ook de
systeemlocale voor oudere niet-Unicode-programma's op en-US.

Gebruik -Keyboard USInternational voor US-International of -Keyboard US
voor normaal US. Zonder parameter is US de standaard; het codeblok op de
webpagina kiest US-International. Overige talen blijven beschikbaar.

Datum- en getalnotatie blijven behouden. Land/regio van het uitvoerende account
en tijdzone worden niet aangepast. Het kopieren naar systeemaccounts en nieuwe
gebruikers neemt de regio-instellingen van het uitvoerende account mee.

Andere bestaande gebruikers behouden hun eigen taalvoorkeur. Als je bij UAC
een ander administratoraccount invoert, is dat het uitvoerende account.
Gebruik een aangemeld account, niet SYSTEM. Windows 11-edities met slechts
een toegestane weergavetaal worden geweigerd.

**Herstart Windows na afloop.** De scripts herstarten niet automatisch.
Al uitgevoerde stappen worden bij een fout niet teruggedraaid. Na het
oplossen van de fout kun je het betreffende script opnieuw uitvoeren.

## Fouten en controle

De uitvoer vermeldt het logbestand, onder %LOCALAPPDATA%\JindaOperations\Logs
van het uitvoerende account. Het configuratiescript meldt de concrete fout
en de plek in het script. Bij een UAC-fout verschijnt de melding in het
oorspronkelijke venster, voordat een log kan worden gestart.

Exitcodes: 0 geslaagd, 1 fout, 3010 software geinstalleerd maar herstart nodig.
Het webvoorbeeld gaat bij 3010 door met configureren en stopt bij overige fouten.

Optioneel ondersteunt elk script -WhatIf: dan geen UAC, downloads,
software-installatie, logaanmaak of wijzigingen. Het webvoorbeeld voert
de scripts echt uit, zonder proefrun.

Tests simuleren WinGet, beheerrechten, herstarten onder een andere runtime en
Windows-instellingen. Ze installeren geen software en veranderen geen taal.
Voer vanuit deze map in Windows PowerShell 5.1 uit:

~~~powershell
Invoke-Pester -Script .\tests
~~~

De runtime-tests kunnen ook in PowerShell 7 met dezelfde Pester-module draaien.
Een echte UAC-/installatie-/taalwijzigingsronde moet op de doel-pc worden getest.

## Publicatie en bronnen

GitHub Pages publiceert de hoofdmap van main; de twee vaste script-URL's volgen
de gepubliceerde versie. Er zijn geen losse scripts per programma of instelling.

Microsoft:
[PowerShell installeren](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows),
[Windows PowerShell-compatibiliteit](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility),
[Install-Language](https://learn.microsoft.com/en-us/powershell/module/languagepackmanagement/install-language),
[Copy-UserInternationalSettingsToSystem](https://learn.microsoft.com/en-us/powershell/module/international/copy-userinternationalsettingstosystem).
