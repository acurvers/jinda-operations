# Jinda Operations voor Windows Server 2012

**Auteur** Codex (AI)

**Model** GPT-6.1-sol

**Datum** 2026-11-24

**Doel** Alleen toegang op afstand inrichten op een bestaande Windows Server 2012/R2

**Onderwerp** RDP, WinRM en IPv4-ping met Windows PowerShell 3.0

Start via [de Server-webpagina](https://acurvers.github.io/jinda-operations/windows-server.html).
Deze bevat één kopieerbare opdracht die `windows-server.zip` downloadt, de SHA-256
controleert en het script start. TLS 1.2 wordt voor die download ingeschakeld;
certificaatcontrole blijft aan. Geen WinGet, PowerShell-upgrade of extra modules.

Het script schakelt zo nodig van x86 naar de ingebouwde 64-bits Windows PowerShell
en vraagt administratorrechten. Alle keuzes staan aan het begin: RDP, WinRM, ping,
de LAN-adapter (bij meerdere adressen) en toegestane IPv4-adressen/subnetten.
Enter kiest bij de drie onderdelen Yes. No slaat het onderdeel over en schakelt
bestaande toegang niet uit. De standaardbron is het gekozen LAN-subnet. Voeg
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
| WinRM | Ingebouwde Windows PowerShell-remoting op HTTP/TCP 5985; Basic en AllowUnencrypted uit; kan WinRM herstarten |
| Ping | Eigen inkomende ICMPv4 echo-regel, type 8 |
| Windows Firewall met geavanceerde beveiliging op de doelserver | Geselecteerde standaardregels en eigen pingregel: alle netwerkprofielen, alleen gekozen interface/lokaal IPv4 en opgegeven bronadressen |

Het script controleert vooraf de Server-versie, de gekozen adapter, actieve
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
