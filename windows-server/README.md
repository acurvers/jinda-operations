# Jinda Operations voor Windows Server 2012

**Auteur** Codex (AI)

**Model** Onbekend

**Datum** 2026-11-24

**Doel** Alleen toegang op afstand inrichten op een bestaande Windows Server 2012/R2

**Onderwerp** RDP, bestaand WinRM en optionele Windows Firewall-regelconfiguratie op de doelserver met Windows PowerShell 3.0

Start via [de Server-webpagina](https://acurvers.github.io/jinda-operations/windows-server.html).
Deze bevat één kopieerbare opdracht die `windows-server.zip` downloadt, de SHA-256
controleert en het script start. TLS 1.2 wordt voor die download ingeschakeld;
certificaatcontrole blijft aan. Geen WinGet, PowerShell-upgrade of extra modules.

Het script schakelt zo nodig van x86 naar de ingebouwde 64-bits Windows PowerShell
en vraagt administratorrechten. Alle keuzes staan aan het begin: RDP, WinRM, ping
en bij iedere uitvoering een aparte vraag over **Windows Firewall met geavanceerde
beveiliging op de doelserver**, standaard **No**. Deze vraag blijft komen wanneer
RDP, WinRM en ping via parameters zijn ingevuld. De keuze wordt niet onthouden.
Alleen bij Yes volgen de LAN-adapter (bij meerdere adressen) en toegestane
IPv4-adressen/subnetten. Enter kiest bij de eerste drie onderdelen Yes. No slaat
het onderdeel over en schakelt bestaande toegang niet uit. De standaardbron bij
regelconfiguratie is het gekozen LAN-subnet. Voeg
beheer- of VPN-adressen uit andere subnetten zelf toe in dezelfde vraag.

Vooraf ingevulde keuzes, bijvoorbeeld:

```powershell
.\Enable-ServerRemoteAccess.ps1 -RemoteDesktop Yes -WinRM Yes -Ping Yes -LanIPAddress 192.168.40.20 -AllowedRemoteAddresses 192.168.40.0/24,10.6.0.3
```

**192.168.40.20 is een voorbeeld**, geen vast serveradres. Een rechtstreeks
gedownload script start je zo nodig met `powershell.exe -NoProfile -ExecutionPolicy
Bypass -File <pad>`. `-WhatIf` voert geen inrichting, elevatie of logaanmaak uit.

## Wat wordt ingericht?

| Onderdeel | Gedrag |
| --- | --- |
| RDP | Bestaande RDP-poort, TCP/UDP, NLA aan; TermService automatisch starten, geen serviceherstart |
| WinRM | Bij regelconfiguratie Yes: ingebouwde Windows PowerShell-remoting op HTTP/TCP 5985; Basic en AllowUnencrypted uit; kan WinRM herstarten. Bij No: bestaande WinRM-inrichting blijft volledig staan; alleen een geselecteerde lokale listenercontrole. WinRM zelf op No slaat ook die controle over. |
| Ping | Alleen bij regelconfiguratie Yes: eigen inkomende ICMPv4 echo-regel, type 8. Bij No wordt pingconfiguratie overgeslagen. |
| Windows Firewall met geavanceerde beveiliging op de doelserver | Elke run een aparte keuze, standaard No. No slaat alle profiel-/regelcontroles en regelwijzigingen over; Yes begrenst de geselecteerde standaardregels en eigen pingregel tot gekozen interface/lokaal IPv4 en opgegeven bronnen. |

Bij No voor Windows Firewall met geavanceerde beveiliging op de doelserver gebruikt
het script ook geen `Enable-PSRemoting`, omdat die opdracht zelf regels wijzigt.
Een ontbrekende reactie op de optionele lokale WinRM-controle geeft dan een melding
en blokkeert RDP-configuratie niet. Een antwoord van de listener bewijst nog geen
geslaagde remote PowerShell-aanmelding. Bestaande regels en diensten kunnen externe
toegang nog steeds blokkeren; No schakelt Windows Firewall niet uit.

Het script controleert vooraf de Server-versie en het bestaande RDP-beleid/-poort.
Alleen bij regelconfiguratie Yes controleert het ook de gekozen adapter, actieve
Windows Firewall-profielinstellingen op de doelserver en centraal beheerde regels.
Een beleidsconflict stopt de inrichting. Andere custom regels blijven bestaan en
kunnen dus extra toegang toestaan of blokkeren. Het script is geen volledige
controle van de effectieve netwerktoegang. De gekozen lokale adresbinding moet
opnieuw worden ingesteld als het server-IP verandert.

Er worden geen apps, taalinstellingen, account-/wachtwoordbeleid, TrustedHosts,
routeringsregels of routerinstellingen aangepast. WinRM gebruikt de bestaande
Windows-authenticatie; gebruik een bestaand bevoegd account. HTTP-WinRM met
Negotiate gebruikt berichtversleuteling; dit script richt geen HTTPS-certificaat in.
Het stelt geen nieuwe accountrechten of UAC-uitzonderingen in.

Vanaf de beheer-pc:

```powershell
Enter-PSSession -ComputerName SERVERNAAM -ConfigurationName Microsoft.PowerShell -Authentication Negotiate -Credential (Get-Credential)
```

Gebruik bij voorkeur de domeinnaam van de server voor Kerberos. Verbinding via een
IP-adres of buiten een domein kan een afzonderlijke TrustedHosts- of HTTPS-inrichting
op de beheer-pc vereisen. De sessie draait in de Windows PowerShell-versie die al
op de server aanwezig is. De server wordt niet automatisch herstart.

Logs komen in `%LOCALAPPDATA%\JindaOperations\Logs`. Reeds uitgevoerde wijzigingen
worden bij een latere fout niet automatisch teruggedraaid. Test RDP, WinRM en ping
vanaf de beheer-pc na uitvoering. Windows Server 2012/R2 is uit ondersteuning;
dit script vernieuwt het besturingssysteem niet.

## Pakket bijwerken en controleren

Na een bronwijziging: `tools\Build-WindowsServerPackage.ps1`. Dit bouwt de aparte
root-download `windows-server.zip` met alleen dit script en deze README, en werkt
de SHA-256 in `windows-server.html` bij. Commit bron, ZIP en webpagina samen.

Offline tests: `Invoke-Pester .\tests\windows-server.Tests.ps1`.
Publicatiecontrole: `tools\Test-WindowsServerPublication.ps1 -CommitSha <SHA>`.
Deze vergelijkt de gedownloade ZIP en de webpagina met de exacte Git-commit,
controleert de uitgepakte bronbestanden en vereist een geslaagde Pages-run.

De tests simuleren servercommando's en wijzigen de beheer-pc niet. Een echte
Windows Server 2012/PowerShell 3.0-runtime is hier niet beschikbaar voor een
integratietest. Compatibiliteit is gebaseerd op de gebruikte PowerShell 3.0-syntax,
Windows Server 2012-cmdlets en tests met bestaande Windows PowerShell 5.1-tooling.

Bronnen: [Enable-PSRemoting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enable-psremoting?view=powershell-5.1),
[Windows Firewall-regels via NetSecurity](https://learn.microsoft.com/en-us/powershell/module/netsecurity/set-netfirewallrule),
[WinRM-beveiliging](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/winrm-security).
