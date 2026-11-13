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

Init biedt Windows Hello eerst aan vanuit de sessie van de ingelogde gebruiker.
Na de eventuele UAC-vraag stelt init de overige vragen voordat het apps downloadt
of Windows configureert.

De eigen vragen, statusmeldingen, waarschuwingen en foutmeldingen van de drie scripts
zijn in het Engels. Uitvoer van Windows, WinGet en andere externe programma's volgt
hun eigen taalinstelling.

**Keuzes bij de start**

| Vraag | Enter kiest | Bij nee |
| --- | --- | --- |
| Set up a Windows Hello PIN for this Windows account? | Nee | Slaat Windows Hello over |
| Install essential apps (VS Code, Everything, Notepad++, Chrome and LastPass)? | Ja | Slaat de vijf essentiële apps over |
| Install optional apps? | Nee | Slaat de overige apps over |
| Enable Remote Desktop (RDP) on the LAN? | Nee | Bestaande RDP-instellingen blijven ongemoeid |
| Enable PowerShell remoting (WinRM) on the LAN? | Nee | Bestaande WinRM-instellingen blijven ongemoeid |
| Install OpenSSH for the selected LAN and authorize the salon SSH key for local users? | Nee | OpenSSH-installatie, service, firewall en sleutels blijven ongemoeid |
| Uninstall unwanted apps? | Nee | LinkedIn en Microsoft Solitaire Collection blijven staan |

Bij een RDP-, WinRM- of OpenSSH-keuze gebruikt init het actieve IPv4-adres. Zijn er meerdere,
dan kies je ook het LAN aan het begin. Er is geen vast pc-adres ingebouwd.
Daarna draaien de deelscripts met `-NonInteractive`; ze stellen geen verdere vragen.
De Windows-taalconfiguratie wordt ook uitgevoerd als je apps overslaat.

De PIN-vraag verschijnt alleen op het interactieve Windows-bureaublad wanneer
Windows Hello voor die gebruiker nog niet is ingesteld. Bij **Y** opent Windows
de eigen dialoog waarin je de PIN invoert. Ga daarna terug naar PowerShell en
druk op Enter om de setup te vervolgen. Heeft het lokale account een leeg
wachtwoord, stel dan eerst een wachtwoord in. Met `-WindowsHelloPin No` kun je
de stap overslaan.

Voor vooraf ingevulde keuzes kun je `-InstallEssentialApps Yes|No`, `-InstallOptionalApps Yes|No`,
`-RemoteDesktop Yes|No`, `-PowerShellRemoting Yes|No`, `-OpenSSH Yes|No` en
`-RemoveBundledApps Yes|No` aan init meegeven. Het bestaande `-InstallApps Yes|No`
vult de keuze voor beide groepen in. Een expliciete keuze per groep heeft voorrang.
Gebruik bij meerdere
netwerkadressen een expliciet `-LanIPAddress` om ook de LAN-keuze vooraf in te vullen.

OpenSSH heeft een eigen keuze, onafhankelijk van apps installeren, RDP en WinRM.
Kies bij beide appgroepen **N** en bij OpenSSH **Y** om alleen de SSH-onderdelen
te installeren. Daarna volgt de normale Windows-configuratie.
RDP, WinRM en SSH gebruiken dezelfde LAN-keuze.

Met **Y** bij verwijderen ruimt de configuratie de Windows-apps LinkedIn en Microsoft Solitaire Collection op
voor bestaande gebruikers en haalt ze uit de standaardinstallatie voor nieuwe gebruikers. Dit werkt ook als je beide appgroepen overslaat.

## Optioneel WinGet-herstel

Bij WinGet-bronfouten zoals `0x8A15000F` gebruik je dezelfde oneliner met
`-RepairWinGet` na `-File $p`:

~~~powershell
& { $ErrorActionPreference = "Stop"; $p = "$env:TEMP\jinda-$([guid]::NewGuid().ToString('N'))"; iwr https://github.com/acurvers/jinda-operations/archive/refs/heads/main.zip -UseBasicParsing -OutFile "$p.zip" -TimeoutSec 60; Expand-Archive -LiteralPath "$p.zip" -DestinationPath $p; powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\jinda-operations-main\init.ps1" -RepairWinGet }
~~~

Deze optionele switch installeert/bijwerkt `Microsoft.WinGet.Client` uit PSGallery
voor het uitvoerende account en voert `Repair-WinGetPackageManager -Force -Latest`
uit. In Windows PowerShell 5.1 wordt zo nodig eerst de NuGet-provider toegevoegd.
Als apps installeren is gekozen, herstelt init na de beginvragen WinGet. Daarna
ververst en controleert het installatiescript de pakketindex voordat het apps installeert.
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
Een fout bij Google Chrome geeft een waarschuwing en laat de overige apps en
configuratie doorgaan. WinGet probeert Store-apps stil te installeren in de
huidige Windows-sessie. Bij een bekende Store-aanmeldfout slaat het script alleen
de betreffende app over en noemt die in een waarschuwing. In Windows-servicesessie
0 (zoals via SSH) slaat het script ook Codex desktop over, omdat de MSIX-installatie
een interactieve Windows-sessie vereist. Andere installatiefouten breken de setup af.
Een software-exitcode 3010 (herstart nodig) laat de configuratie doorgaan. Als de installatie of configuratie
3010 teruggeeft, meldt init aan het eind dat een herstart nodig is. Init start Windows niet zelf opnieuw op.

## Microsoft Store-updates

De Windows-configuratie zet automatische Store-updates aan voor de hele pc en
vraagt een updatescan aan via de ingebouwde Windows-taak `ScanForUpdates`.
Windows verwerkt de scan en beschikbare Store-updates op de achtergrond.
De setup meldt een waarschuwing als de scan niet kan starten.

## Standaardbeleid voor lokale Windows-accounts

Het configuratiescript zet `LimitBlankPasswordUse` op `0`. Daardoor staat
Windows externe aanmelding met een leeg wachtwoord toe voor lokale accounts
op deze pc. Deze instelling geldt ook voor andere netwerkdiensten. RDP en
WinRM behouden hun eigen aanmeldvereisten en toegangsrechten. Centraal beleid
kan deze lokale instelling overschrijven.

[Microsoft-documentatie over lege wachtwoorden](https://learn.microsoft.com/en-us/windows/security/threat-protection/security-policy-settings/accounts-limit-local-account-use-of-blank-passwords-to-console-logon-only)

Het configuratiescript stelt de maximale wachtwoordleeftijd voor lokale
Windows-accounts in op **onbeperkt**, met `net.exe accounts /maxpwage:unlimited`.
Dit geldt voor bestaande en later aangemaakte lokale accounts, dus ook voor
het balieaccount en het lokale beheeraccount. De stap draait bij iedere normale
configuratierun, ook als apps installeren wordt overgeslagen. Opnieuw uitvoeren
stelt dezelfde waarde in; er komt geen extra taak of software bij.

Er worden geen wachtwoorden veranderd, accounts geactiveerd, vergrendelingen
opgeheven of andere wachtwoord-/lockoutregels aangepast. Deze instelling gaat
alleen over periodiek vervallen door ouderdom; een verplichte wachtwoordwijziging
bij de volgende aanmelding is een afzonderlijke accountinstelling. Domein- en
cloudwachtwoorden vallen hier niet onder. Centraal beleid kan de lokale
instelling later opnieuw overschrijven.

De uitvoer en het bestaande transcript tonen de accountpolicy na het toepassen.
Bij een fout stopt configuratie met een concrete melding. `-WhatIf` past niets aan.
De wijziging wordt pas actief nadat deze scriptversie op de doel-pc is uitgevoerd.

Alleen controleren vanuit een gewone PowerShell (geen wachtwoorden in de uitvoer):

~~~powershell
net user PC
Get-LocalUser -Name 'PC' | Select-Object Name, Enabled, PasswordLastSet, PasswordExpires
net accounts
~~~

`net user PC` toont onder **Password expires** de vervaldatum of **Never**;
`Get-LocalUser` toont die datum als `PasswordExpires` (leeg als er geen datum is).
Een verstreken vervaldatum wees op verlopen geldigheid. `Enabled` alleen zegt
daar niets over. `net accounts` toont de algemene maximumleeftijd (zoals de
eerdere 42 dagen), niet de vervaldatum van een specifiek account. Na herstel
tonen deze commando's de huidige toestand, niet de eerdere storing.

Bron: [Microsoft: lokale account- en wachtwoordpolicy met net accounts](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/net-commands-on-operating-systems).

## Browserfavorieten

Het configuratiescript voegt voor alle Windows-gebruikers een beheerde map **Jinda**
toe aan Chrome en Edge, met **Jinda Operations** als link naar de instructiepagina.
Dit gebeurt ook als je apps installeren overslaat. Persoonlijke favorieten blijven
ongemoeid; de beheerde link is niet handmatig te wijzigen en wordt niet gesynchroniseerd.
Een al aanwezige link wordt niet opnieuw toegevoegd. Heeft de lokale beheerde
favorietenlijst al een andere mapnaam, dan komt Jinda als submap daarin; bestaande
items en mapnamen blijven behouden. Ongeldige bestaande policydata worden niet overschreven.

De browsers hoeven niet te worden gesloten: de link verschijnt na de volgende
policyverversing of browserstart. De favorietenbalk wordt niet verplicht zichtbaar
gemaakt. Controleer zo nodig `chrome://policy` of `edge://policy`.
De instellingen zijn `ManagedBookmarks` (Chrome) en `ManagedFavorites` (Edge), als
JSON-string onder de bijbehorende `HKLM:\SOFTWARE\Policies`-sleutel.
Centraal browserbeheer kan andere policywaarden afdwingen of lokale instellingen
overschrijven; dit script wijzigt geen centraal beheer of policyprioriteiten.

**Edge-beperking:** de policy geldt volgens Microsoft niet voor browserprofielen
die met een persoonlijk Microsoft-account zijn aangemeld. Dit is een beperking van
de gekozen beheerde-favorietenmethode, niet van het Windows-account.
Bronnen: [Chrome ManagedBookmarks](https://chromeenterprise.google/policies/#ManagedBookmarks)
en [Edge ManagedFavorites](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/ManagedFavorites).

## Software

### Apps overslaan met skip-apps.conf

In [skip-apps.conf](skip-apps.conf) staan alle app-ID's al uitgecommentarieerd.
Verwijder het eerste `#` van een appregel om de installatie **en updates** van
die app over te slaan. Bijvoorbeeld:

~~~text
# Google.Chrome     # Normale installatie/update blijft aan
9NKSQGP7F2NH        # WhatsApp overslaan
~~~

Standaard slaat het bestand niets over. Een overgeslagen app wordt niet verwijderd;
bij VS Code wordt ook de bijbehorende PowerShell-extensie overgeslagen.
Discord en Teams blijven tijdelijk uitgeschakeld in het script, ongeacht deze lijst.
Yodeck heeft de vaste sleutel `Yodeck.Player`. Lege regels en tekst na `#` worden
genegeerd; hoofdletters maken niet uit. Een onbekende ID of ontbrekend bestand
stopt de installatie met een foutmelding voordat WinGet iets bijwerkt.

Voor een uitzondering op één pc maak je `C:\Support\skip-apps.conf` aan.
Zet daarin één app-ID per regel, bijvoorbeeld `TeamViewer.TeamViewer`. De
installer leest die lijst bij elke start en voegt de lokale keuzes toe aan
de lijst uit het downloadpakket. Zonder lokaal bestand geldt de lijst uit
het pakket. Als alle apps zijn overgeslagen, wordt ook de WinGet-update
overgeslagen.

### Installatielijst

Voor de apps ververst het installatiescript de bron met `winget source update --name winget`.
Het controleert daarna of de geregistreerde pakketindex minstens zo nieuw is als de
versie die Microsoft aan het begin van de controle aanbiedt. Een actuele index is
voldoende. Als WinGet succes meldt terwijl de index ontbreekt of achterblijft,
registreert setup het officiële Microsoft-bronpakket voor het
uitvoerende account en controleert de versie opnieuw. Bij een bronfout of een
achterblijvende of oncontroleerbare index stopt setup vóór de app-installatie
en de Windows-configuratie.

Daarna werkt het installatiescript WinGet zelf bij via
`winget upgrade --id Microsoft.AppInstaller --exact --source winget`.
Dit gebeurt zonder extra vragen en alleen als een nieuwere versie beschikbaar is;
er is geen extra PowerShell-module nodig. Bij een echte updatefout stopt het script
voordat de apps beginnen. Kies je aan het begin geen app-installatie, dan wordt
ook deze WinGet-update overgeslagen.

VS Code, Everything, Notepad++, Chrome en LastPass zijn essentieel. De overige
apps vallen onder de optionele keuze. `skip-apps.conf` geldt voor beide groepen.

| App | Pakket / bron | Installatiebereik |
| --- | --- | --- |
| Chrome | Google.Chrome / winget | Alle gebruikers |
| TeamViewer | TeamViewer.TeamViewer / winget, volledige nullsoft-client | Alle gebruikers |
| PowerShell 7 | Microsoft.PowerShell / winget, stabiele MSI (wix) | Alle gebruikers |
| OpenSSH client en server (eigen y/n-keuze; standaard Nee) | Windows optional features / `Windows.OpenSSH` in skip-apps.conf | Alle gebruikers; SSH-service en LAN-firewallregel |
| VS Code | Microsoft.VisualStudioCode / winget | Alle gebruikers |
| OneNote | XPFFZHVGQWWLHB / msstore | Standaard van installer |
| Notepad++ | Notepad++.Notepad++ / winget | Alle gebruikers |
| Discord (tijdelijk uitgeschakeld) | Discord.Discord / winget | Wordt momenteel niet geinstalleerd |
| Reolink Client | Reolink.Reolink / winget | Standaard van installer |
| Paint.NET | dotPDN.PaintDotNet / winget | Alle gebruikers |
| LastPass | LastPass.LastPass / winget | Standaard van installer |
| Git inclusief Git Bash | Git.Git / winget | Alle gebruikers |
| Zoom | Zoom.Zoom / winget | Alle gebruikers |
| Teams (tijdelijk uitgeschakeld) | Microsoft.Teams / winget, MSIX | Wordt momenteel niet geinstalleerd |
| VLC | VideoLAN.VLC / winget | Alle gebruikers |
| Everything | voidtools.Everything / winget | Alle gebruikers |
| Beyond Compare 5 (proefversie; licentie apart) | ScooterSoftware.BeyondCompare.5 / winget | Alle gebruikers, Engels |
| ChatGPT Classic | 9NT1R1C2HH7J / msstore | Standaard van Store |
| Codex desktop (nu ChatGPT) | OpenAI.ChatGPT / winget, MSIX | Uitvoerende gebruiker |
| Signal | OpenWhisperSystems.Signal / winget | Uitvoerende gebruiker |
| OBS Studio | OBSProject.OBSStudio / winget, nullsoft | Alle gebruikers |
| Adobe Acrobat Reader (64-bit) | Adobe.Acrobat.Reader.64-bit / winget | Alle gebruikers |
| Yodeck Player | Officiele Yodeck Windows-installer | Alle gebruikers |
| WhatsApp | 9NKSQGP7F2NH / msstore | Standaard van Store |

WhatsApp wordt als laatste app geprobeerd, na Yodeck. Dezelfde afhandeling voor Store-aanmeldfouten geldt voor WhatsApp.

OpenSSH wordt via de ingebouwde Windows-onderdelen geinstalleerd, met
`Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` en
hetzelfde commando voor `OpenSSH.Server~~~~0.0.1.0`. Reeds aanwezige onderdelen
worden overgeslagen; verdere updates lopen via Windows Update. De service `sshd`
wordt gestart en op automatisch starten gezet. De standaardfirewallregel
`OpenSSH-Server-In-TCP` staat TCP 22 toe op de gekozen adapter en het
bijbehorende lokale IPv4-adres, met het gekozen IPv4-subnet als bron. De
regel geldt op alle netwerkprofielen, waaronder Public. Het netwerkprofiel
van de adapter blijft zoals Windows het heeft ingesteld.

Gebruik een bestaand Windows-account met wachtwoord (geen Windows Hello-pincode)
of een SSH-sleutel. De firewallregel betreft TCP 22. Het script behoudt
`sshd_config`, inclusief een eventueel afwijkende luisterpoort.
Als Windows een herstart vereist, meldt het script dat en moet setup na die herstart
nogmaals draaien om de service te activeren. Setup herstart Windows niet zelf.
Na het starten van `sshd` toont de installer de luisteraars op TCP 22 en de
actieve firewallregel. Hij waarschuwt als `sshd` op die poort niet op het
gekozen IPv4-adres luistert. De installer geeft een fout als de effectieve
firewallregel afwijkt of Windows de regel niet toepast.

Alleen **Y** bij de OpenSSH-vraag voert deze stap uit. **N** slaat hem over en
deactiveert geen eerder ingerichte SSH-service. `Windows.OpenSSH` activeren in
`skip-apps.conf` slaat de stap ook bij **Y** over, met een melding in de uitvoer.
Rechtstreeks `install-software.ps1` uitvoeren installeert standaard geen OpenSSH;
gebruik daarvoor expliciet `-EnableOpenSSH`, eventueel met `-SkipApps` voor alleen SSH.
Geef bij meerdere actieve LAN-adressen ook `-LanIPAddress <actief-IPv4-adres>` mee.
Het deelscript stelt geen vragen; de y/n-vraag staat vooraf in `init.ps1`.
De RDP/WinRM-keuzes regelen afzonderlijke protocollen.
Bron: [Microsoft: OpenSSH voor Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).

### SSH-sleutel voor de salon-pc's

Gebruik de gewone startopdracht en kies **Y** bij OpenSSH. `init.ps1` geeft dan
de publieke Ed25519-sleutel `salon-oss-admin` door. Met `-SshPublicKey` kun je
desgewenst een andere publieke Ed25519-sleutel opgeven. De privésleutel hoort
op de beheer-pc.

Setup voegt de sleutel toe naast de bestaande sleutels voor ingeschakelde
lokale Windows-gebruikers. Het gebruikt het eigen `.ssh\authorized_keys` voor
standaardgebruikers en het gedeelde `administrators_authorized_keys` voor
beheerders. Zo nodig initialiseert Windows eerst het profiel van een
standaardgebruiker. De SSH-server moet deze standaard Windows-sleutelbestanden
gebruiken en sleutelverificatie toestaan.
[Microsoft over SSH-sleutels op Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)

ChatGPT Classic en de Codex-desktopapp zijn aparte apps. De huidige
[Codex-desktopapp heet ChatGPT](https://learn.chatgpt.com/docs/windows/windows-app)
en wordt via WinGet als `OpenAI.ChatGPT` aangeboden. `OpenAI.Codex` is de
afzonderlijke CLI en wordt hier niet geinstalleerd. Zelf inloggen op de
OpenAI-apps en Signal koppelen aan je telefoon blijft nodig.

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
- WinRM: PowerShell 7-remoting via `PowerShell.7` op HTTP/TCP 5985, Windows-authenticatie;
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

Bij WinRM = Y gebruikt de configuratie de nieuwste geinstalleerde stabiele,
native 64-bits PowerShell 7 om het endpoint `PowerShell.7` in te richten.
Een ouder endpoint wordt bijgewerkt met behoud van zijn toegangsrechten.
De app-installatie werkt PowerShell vooraf bij als er een update beschikbaar is.
Bij apps = N wordt de nieuwste al aanwezige versie gebruikt; ontbreekt PowerShell 7,
dan stopt de configuratie vooraf met een duidelijke melding. WinRM = N laat ook
dit endpoint ongewijzigd. De inrichting kan de WinRM-service herstarten.

De WinRM-beveiligingsstap leest eerst `AllowUnencrypted` en `Basic`. Waarden die
al `false` zijn, worden niet opnieuw geschreven: ook een overbodige schrijfopdracht
kan op een Public-netwerk een fout opleveren. Alleen ingeschakelde waarden worden
uitgezet en daarna opnieuw uitgelezen. Ontbrekende waarden, lees-/schrijffouten of
een mislukte verificatie stoppen de configuratie met een foutmelding. De stap meldt
de geverifieerde waarden in de console en het bestaande transcript.

Verbind vanaf je beheer-pc expliciet met het PowerShell 7-endpoint:

~~~powershell
$cred = Get-Credential
Enter-PSSession -ComputerName 192.168.50.200 -ConfigurationName PowerShell.7 -Authentication Negotiate -Credential $cred
~~~

Dit geldt ook voor `Invoke-Command` en `New-PSSession`. Zonder
`-ConfigurationName PowerShell.7` kiest de client nog het bestaande
Windows PowerShell 5.1-endpoint. Zie de
[Microsoft-uitleg over PowerShell 7-remoting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enable-psremoting?view=powershell-7.6).

Het script controleert het actuele adres, de Windows-editie, firewall en blokkerend
beleid voordat de Windows-configuratie wijzigt. De instellingen blijven na herstart
bestaan. Bij een later gewijzigd IP-adres moet de begrenzing opnieuw worden ingesteld.
Een echte RDP-/WinRM-aanmelding moet vanaf de beheer-pc worden gecontroleerd.
WinRM-clientinstellingen zijn een afzonderlijke stap.

## Fouten en controle

De uitvoer vermeldt het logbestand, onder %LOCALAPPDATA%\JindaOperations\Logs
van het uitvoerende account. In het init-transcript staat onder `Setup choices`
welke opties de setup gaat uitvoeren, inclusief de gekozen LAN-adapter als die
van toepassing is. Voor Windows Hello staat er alleen de status van de instelstap.
Het configuratiescript meldt de concrete fout
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

Controleer de drie scripts en skip-apps.conf rechtstreeks via GitHub met de volledige commit-SHA:

~~~powershell
.\tools\Test-PagesPublication.ps1 -ScriptsOnly -CommitSha <volledige-40-tekens-commit-SHA>
~~~

Deze alleen-lezen-controle vergelijkt de bytes in het GitHub-ZIP-pakket van `init.ps1`,
`install-software.ps1`, `set-windows-english.ps1` en `skip-apps.conf` met de opgegeven GitHub-commit.
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
