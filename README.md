# Jinda Operations

Twee vaste scripts voor Windows 11 Pro. Nieuwe software voegen we toe aan
[install-software.ps1](install-software.ps1); nieuwe instellingen aan
[set-windows-english.ps1](set-windows-english.ps1).

De [instructiepagina](https://acurvers.github.io/jinda-operations/) bevat de
eenregelige startopdracht voor [init.ps1](init.ps1). Init start
de gekozen installatie en configuratie achter elkaar; de inhoud blijft in de twee vaste scripts.

De scripts komen rechtstreeks uit GitHub, onafhankelijk van GitHub Pages.
De startopdracht haalt eenmaal het ZIP-pakket van main op en gebruikt daaruit
init en beide deelscripts. Zo horen alle scripts bij dezelfde versie, zonder
GitHub API-verzoek. Alleen de instructiewebpagina gebruikt Pages.
Een fout bij het ophalen stopt de uitvoering; er wordt geen oud lokaal script gestart.

## Starten

~~~powershell
& { $ErrorActionPreference = "Stop"; $p = "$env:TEMP\jinda-$([guid]::NewGuid().ToString('N'))"; iwr https://github.com/acurvers/jinda-operations/archive/refs/heads/main.zip -UseBasicParsing -OutFile "$p.zip" -TimeoutSec 60; Expand-Archive -LiteralPath "$p.zip" -DestinationPath $p; powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\jinda-operations-main\init.ps1" }
~~~

Download en uitpakken moeten slagen voordat init start. De startopdracht voert de scripts
direct uit. Voeg voor een normaal US-toetsenbord -Keyboard US toe na -File $p,
voor de afsluitende accolade; standaard kiest init US-International.

## Keuzes vooraf

Na de eventuele UAC-vraag stelt init alle vragen voordat apps worden gedownload of Windows wordt aangepast:

De eigen vragen, statusmeldingen, waarschuwingen en foutmeldingen van de drie scripts
zijn in het Engels. Uitvoer van Windows, WinGet en andere externe programma's volgt
hun eigen taalinstelling.

**Keuzes bij de start**

| Vraag | Enter kiest | Bij nee |
| --- | --- | --- |
| Download and install apps? | Ja | Geen apps downloaden/installeren en geen WinGet-herstel |
| Enable Remote Desktop (RDP) on the LAN? | Nee | Bestaande RDP-instellingen blijven ongemoeid |
| Enable PowerShell remoting (WinRM) on the LAN? | Nee | Bestaande WinRM-instellingen blijven ongemoeid |

Bij een remote-keuze gebruikt init het actieve IPv4-adres. Zijn er meerdere,
dan kies je ook het LAN aan het begin. Er is geen vast pc-adres ingebouwd.
Daarna draaien de deelscripts met `-NonInteractive`; ze stellen geen verdere vragen.
De Windows-taalconfiguratie wordt ook uitgevoerd als je apps overslaat.

Voor vooraf ingevulde keuzes kun je `-InstallApps Yes|No`, `-RemoteDesktop Yes|No`,
`-PowerShellRemoting Yes|No` en zo nodig `-LanIPAddress <actief-IPv4-adres>` aan
init meegeven. Zonder deze parameters gebruikt init `Ask`. Gebruik bij meerdere
netwerkadressen een expliciet `-LanIPAddress` om ook de LAN-keuze vooraf in te vullen.

## Optioneel WinGet-herstel

Bij WinGet-bronfouten zoals `0x8A15000F` gebruik je dezelfde oneliner met
`-RepairWinGet` na `-File $p`:

~~~powershell
& { $ErrorActionPreference = "Stop"; $p = "$env:TEMP\jinda-$([guid]::NewGuid().ToString('N'))"; iwr https://github.com/acurvers/jinda-operations/archive/refs/heads/main.zip -UseBasicParsing -OutFile "$p.zip" -TimeoutSec 60; Expand-Archive -LiteralPath "$p.zip" -DestinationPath $p; powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\jinda-operations-main\init.ps1" -RepairWinGet }
~~~

Deze optionele switch installeert/bijwerkt `Microsoft.WinGet.Client` uit PSGallery
voor het uitvoerende account en voert `Repair-WinGetPackageManager -Force -Latest`
uit. In Windows PowerShell 5.1 wordt zo nodig eerst de NuGet-provider toegevoegd.
Als apps installeren is gekozen, herstelt init na de beginvragen WinGet en controleert met
`winget show` of TeamViewer via de winget-bron gevonden wordt. Pas daarna beginnen
installatie en configuratie; bij een herstel- of bronfout stopt init.
Zonder de switch wordt geen herstel uitgevoerd. Ook met de switch doet `-WhatIf`
geen wijzigingen. Zie de [Microsoft-herstelinstructies](https://learn.microsoft.com/en-us/windows/package-manager/winget/troubleshooting).

## Uitvoering

Init en de twee deelscripts vragen zo nodig administratorrechten via Windows UAC en
kiezen de nieuwste aanwezige stabiele PowerShell 7 of hoger voor de native
64-bits architectuur. Ze zoeken in de standaard PowerShell-installatiemappen,
de huidige runtime, PATH en Microsoft Store-installaties. Previewversies
en 32-bits runtimes worden overgeslagen. Zonder geschikte PowerShell 7
starten ze in Windows PowerShell 5.1.

De installatie voegt de nieuwste stabiele PowerShell toe. Het configuratiescript
zoekt daarna opnieuw naar de nieuwste aanwezige versie. Er wordt geen
uitvoeringsbeleid permanent gewijzigd.

De taal- en LAN-configuratie gebruiken intern een verhoogd Windows PowerShell 5.1-proces
van hetzelfde configuratiebestand. Zo blijven de getypeerde Windows-taalobjecten
beschikbaar zonder deserialisatie via de PowerShell-compatibiliteitslaag.
Er is geen extra configuratiescript nodig.

Init vraagt eenmaal om beheerrechten; de twee deelscripts erven die rechten.
Start je al in een administratorvenster, dan volgt geen extra UAC-vraag.
De startopdracht downloadt eerst het complete scriptpakket. Init voert de scripts daarna een voor een uit.
Bij een mislukte download wordt niets geinstalleerd of geconfigureerd.
Alleen een fout bij Google Chrome geeft een waarschuwing en laat de overige apps
en configuratie doorgaan. Chrome wordt wel geprobeerd. Bij een fout in een andere
app stopt de installatie en start de configuratie niet. Een software-exitcode
3010 (herstart nodig) laat de configuratie wel doorgaan en wordt aan het einde
doorgegeven. Init start Windows niet zelf opnieuw op.

## Software

Voor de apps werkt het installatiescript eerst WinGet zelf bij via
`winget upgrade --id Microsoft.AppInstaller --exact --source winget`.
Dit gebeurt zonder extra vragen en alleen als een nieuwere versie beschikbaar is;
er is geen extra PowerShell-module nodig. Bij een echte updatefout stopt het script
voordat de apps beginnen. Kies je aan het begin geen app-installatie, dan wordt
ook deze WinGet-update overgeslagen.

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

WinGet en de Microsoft Store-bron moeten beschikbaar zijn. Alle apps in de
WinGet-lijst worden geinstalleerd of bijgewerkt naar de nieuwste versie die de
gekozen bron aanbiedt. Is er geen nieuwere versie, dan gaat het script verder.
De pakket- en bronvoorwaarden worden automatisch geaccepteerd.
Dezelfde TeamViewer-installatie staat maar eenmaal in de lijst.

Direct na VS Code installeert of actualiseert het script de officiele Microsoft
PowerShell-extensie (`ms-vscode.PowerShell`) zonder extra vragen. Dit gebeurt ook
als VS Code zelf al actueel is. Het script controleert daarna of de extensie is
geinstalleerd en stopt bij een fout. De extensie geldt voor het uitvoerende
Windows-account; bij UAC met een ander administratoraccount geldt dit voor dat account.

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
voor normaal US. Zonder parameter is US de standaard; init op de
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

## Optionele toegang op afstand via LAN en WireGuard

De werking van `Enable-LanRemoteAccess.ps1` is opgenomen in het bestaande
configuratiescript. RDP en WinRM zijn afzonderlijk te kiezen; zonder toestemming
voor dat onderdeel worden de bijbehorende services, instellingen en firewallregels
niet aangepast.

- RDP: NLA aan, bestaande RDP-poort behouden, TCP en UDP; TermService wordt niet herstart.
- WinRM: Windows PowerShell-remoting op HTTP/TCP 5985, Windows-authenticatie;
  Basic en onversleutelde berichten blijven uit.
- Windows-standaardregels voor de gekozen onderdelen staan het werkelijke
  LAN-subnet en WireGuard-client `10.6.0.3` toe. Het gekozen lokale IPv4-adres
  en de LAN-interface blijven de bestemming. Dit geldt voor RDP (TCP/UDP)
  en de WinRM-regels, ook nadat Windows remoting opnieuw configureert.
- Zodra RDP of WinRM wordt gekozen, staat de eigen regel
  `Jinda-LAN-WireGuard-ICMPv4-In` ook IPv4-pings (ICMP echo request, type 8)
  toe vanaf hetzelfde LAN-subnet en `10.6.0.3`. Er komen geen extra vragen.
  Bij opnieuw uitvoeren wordt de regel bijgewerkt; er ontstaan geen duplicaten.
  Als beide remote-opties op nee staan, worden ook de pingregels niet aangepast.
- Het netwerkprofiel, accounts, wachtwoorden, TrustedHosts en routerinstellingen
  blijven ongewijzigd. Andere custom firewallregels blijven ongemoeid en kunnen
  de uiteindelijke toegang beinvloeden.

Het script controleert het actuele adres, de Windows-editie, firewall en blokkerend
beleid voordat de Windows-configuratie wijzigt. De instellingen blijven na herstart
bestaan. Bij een later gewijzigd IP-adres moet de begrenzing opnieuw worden ingesteld.
Een echte RDP-/WinRM-aanmelding moet vanaf de beheer-pc worden gecontroleerd.
WinRM-clientinstellingen zijn een afzonderlijke stap.

## Fouten en controle

De uitvoer vermeldt het logbestand, onder %LOCALAPPDATA%\JindaOperations\Logs
van het uitvoerende account. Het configuratiescript meldt de concrete fout
en de plek in het script. Bij een UAC-fout verschijnt de melding in het
oorspronkelijke venster, voordat een log kan worden gestart.

Exitcodes: 0 geslaagd, 1 fout, 3010 software geinstalleerd maar herstart nodig.
Init gaat bij 3010 door met configureren en stopt bij overige fouten, behalve de
Chrome-fout die het installatiescript als waarschuwing behandelt. Een algemene
WinGet-bronfout kan ook de volgende app laten mislukken; dan stopt de installatie.

Optioneel ondersteunt elk script -WhatIf: dan geen UAC, downloads,
software-installatie, logaanmaak of wijzigingen. Het webvoorbeeld voert
de scripts echt uit, zonder proefrun.

Tests simuleren de beginvragen, WinGet, de Yodeck-installer en handtekeningcontrole,
beheerrechten, runtimewissels, Windows-instellingen en LAN/firewall/services.
Ze installeren geen software en veranderen geen taal of remote-toegang.
Voer vanuit deze map in Windows PowerShell 5.1 uit:

~~~powershell
Invoke-Pester -Script .\tests
~~~

De runtime-tests kunnen ook in PowerShell 7 met dezelfde Pester-module draaien.
Een echte UAC-/installatie-/taalwijzigingsronde moet op de doel-pc worden getest.

## Publicatie en bronnen

GitHub Pages publiceert alleen de instructiewebpagina. De startopdracht haalt init
en de twee vaste scripts rechtstreeks uit een GitHub-bronarchief van main. Er zijn geen
losse scripts per programma of instelling.

### Verplichte controle na publicatie

Controleer de drie scripts rechtstreeks via GitHub met de volledige commit-SHA:

~~~powershell
.\tools\Test-PagesPublication.ps1 -ScriptsOnly -CommitSha <volledige-40-tekens-commit-SHA>
~~~

Deze alleen-lezen-controle vergelijkt de bytes in het GitHub-ZIP-pakket van `init.ps1`,
`install-software.ps1` en `set-windows-english.ps1` met de opgegeven GitHub-commit.
Exitcode 0 bevestigt de scriptdownloads. De inrichting zelf gebruikt geen API of token.
De publicatiecontrole gebruikt de GitHub API om met de commit te vergelijken; bij
veel controles kan een beheerder daarvoor tijdelijk `GH_TOKEN` meegeven.

Alleen als de instructiewebpagina is gewijzigd, controleer je ook Pages:

~~~powershell
.\tools\Test-PagesPublication.ps1 -CommitSha <volledige-40-tekens-commit-SHA> -TimeoutSeconds 60
~~~

Deze aparte controle vereist een geslaagde Pages-run en de juiste bytes van
`index.html`. Als Pages nog wacht, meld je dat afzonderlijk; de directe scripts
kunnen al beschikbaar zijn. Start geen inrichting op een pc om publicatie te testen.

Microsoft:
[PowerShell installeren](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows),
[Enable-PSRemoting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enable-psremoting?view=powershell-5.1),
[Firewallregels begrenzen](https://learn.microsoft.com/en-us/powershell/module/netsecurity/set-netfirewallrule),
[Remote Desktop en NLA](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access),
[Windows PowerShell-compatibiliteit](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility),
[Install-Language](https://learn.microsoft.com/en-us/powershell/module/languagepackmanagement/install-language),
[Copy-UserInternationalSettingsToSystem](https://learn.microsoft.com/en-us/powershell/module/international/copy-userinternationalsettingstosystem).
