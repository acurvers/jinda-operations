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

| App | Pakket / bron | Installatiebereik |
| --- | --- | --- |
| Chrome | Google.Chrome / winget | Alle gebruikers |
| TeamViewer | TeamViewer.TeamViewer / winget, volledige nullsoft-client | Alle gebruikers |
| PowerShell 7 | Microsoft.PowerShell / winget, stabiele MSI (wix) | Alle gebruikers |
| VS Code | Microsoft.VisualStudioCode / winget | Alle gebruikers |
| OneNote | XPFFZHVGQWWLHB / msstore | Standaard van installer |
| Notepad++ | Notepad++.Notepad++ / winget | Alle gebruikers |
| Discord | Discord.Discord / winget | Uitvoerend account |
| Reolink Client | Reolink.Reolink / winget | Standaard van installer |
| Paint.NET | dotPDN.PaintDotNet / winget | Alle gebruikers |
| LastPass | LastPass.LastPass / winget | Standaard van installer |
| Git inclusief Git Bash | Git.Git / winget | Alle gebruikers |
| Zoom | Zoom.Zoom / winget | Alle gebruikers |
| Teams | Microsoft.Teams / winget, MSIX | Uitvoerend account |
| WhatsApp | 9NKSQGP7F2NH / msstore | Standaard van Store |
| VLC | VideoLAN.VLC / winget | Alle gebruikers |
| Yodeck Player | Officiele Yodeck Windows-installer | Alle gebruikers |

WinGet en de Microsoft Store-bron moeten beschikbaar zijn. Bestaande apps
worden overgeslagen; PowerShell wordt wel bijgewerkt naar de nieuwste stabiele
versie. De pakket- en bronvoorwaarden worden automatisch geaccepteerd.
Dezelfde TeamViewer-installatie staat maar eenmaal in de lijst.

De opgegeven oude ID's Microsoft.OneNote, LogMeIn.LastPass en WhatsApp.WhatsApp
zijn vervangen door bovenstaande actuele vermeldingen. OneNote gebruikt de
huidige desktopversie, niet de oude OneNote voor Windows 10.

Sommige manifests ondersteunen geen expliciet machinebereik. Daarom wordt
alleen waar ondersteund een bereik afgedwongen. Bij apps voor het uitvoerende
account moet UAC onder het bedoelde account worden bevestigd; een ander
administratoraccount krijgt anders die apps.

Yodeck heeft geen WinGet-pakket. Hetzelfde installatiescript downloadt daarom
de actuele installer via de [officiele Yodeck-download](https://yodeck.link/windowsv2),
controleert de geldige digitale handtekening van Flipnode LLC en voert de
NSIS-installer stil uit. Een bestaande Yodeck Player wordt overgeslagen.
Na installatie controleert het script de Windows-programmaregistratie.

Open Yodeck daarna en koppel de registratiecode zelf aan je account:
[Yodeck-handleiding](https://www.yodeck.com/docs/user-manual/setting-up-the-windows-player-with-the-yodeck-software/).
Accounts worden niet automatisch gekoppeld. Er wordt geen remote
TeamViewer-sessie gestart.

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

Tests simuleren WinGet, de Yodeck-installer en handtekeningcontrole, beheerrechten, herstarten onder een andere runtime en
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
