# Jinda Operations

PowerShell-scripts voor het inrichten van Windows-pc's.

## Google Chrome installeren

- [PowerShell-script downloaden](https://acurvers.github.io/jinda-operations/install-chrome.ps1)
- [Downloadpagina](https://acurvers.github.io/jinda-operations/)
- [Broncode bekijken](https://github.com/acurvers/jinda-operations/blob/main/install-chrome.ps1)

Open PowerShell op de doel-pc. Download het script:

```powershell
$scriptPath = Join-Path $env:TEMP 'jinda-install-chrome.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://acurvers.github.io/jinda-operations/install-chrome.ps1' -OutFile $scriptPath
```

Bekijk desgewenst het gedownloade bestand en voer het daarna uit:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
```

`-ExecutionPolicy Bypass` geldt alleen voor dit PowerShell-proces en verandert
de opgeslagen uitvoeringsinstellingen niet. Organisatiebeleid kan uitvoering
nog steeds blokkeren.

Alleen controleren wat het script zou doen:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WhatIf
```

### Gedrag en vereisten

- Bedoeld voor Windows 11 met Windows PowerShell 5.1 of PowerShell 7.
- WinGet moet beschikbaar zijn via Microsoft App Installer.
- Internettoegang en toestemming voor installatie met beheerrechten zijn nodig.
- Installeert de beschikbare stabiele `Google.Chrome` via de `winget`-bron
  voor alle gebruikers. WinGet kiest de passende architectuur.
- Een door WinGet herkende bestaande installatie wordt overgeslagen;
  dit script is geen updater.
- Accepteert automatisch de voorwaarden van het pakket en de pakketbron.
- De installatie verloopt stil; Windows kan wel een UAC-bevestiging tonen.
- Fouten geven exitcode `1`; een gemelde benodigde herstart geeft `3010`.
  Het script start Windows niet zelf opnieuw op.
- `-WhatIf` controleert de aanwezigheid van WinGet en toont de voorgenomen
  actie zonder WinGet uit te voeren.

## Windows standaard naar Engels (Verenigde Staten)

- [set-windows-english.ps1 downloaden](https://acurvers.github.io/jinda-operations/set-windows-english.ps1)
- [Broncode bekijken](https://github.com/acurvers/jinda-operations/blob/main/set-windows-english.ps1)

Dit script stelt **de systeemstandaard** in, inclusief het aanmeldscherm,
systeemaccounts en nieuw aangemaakte gebruikers. Ook het account dat het script
uitvoert krijgt Engels als weergavetaal.

Open **Windows PowerShell als administrator** op de doel-pc (64-bits, versie
5.1; gebruik `powershell.exe`). Download het script:

```powershell
$scriptPath = Join-Path $env:TEMP 'jinda-set-windows-english.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://acurvers.github.io/jinda-operations/set-windows-english.ps1' -OutFile $scriptPath
```

Engels (VS) met een **US-International-toetsenbord**:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Keyboard USInternational
```

Voor een **normaal US-toetsenbord** gebruik je `-Keyboard US`, of laat je de
parameter weg. US-International gebruikt onder andere dode toetsen voor
accenten; een apostrof verschijnt daardoor soms pas na de volgende toets.

Eerst een proefrun zonder instellingen te veranderen of taalpakketten te downloaden:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Keyboard USInternational -WhatIf
```

**Herstart Windows na de echte uitvoering.** Het script herstart niet zelf.

### Wat wordt ingesteld?

| Onderdeel | Gedrag |
| --- | --- |
| Windows-weergavetaalpakket | Installeert en-US als het volledige taalpakket ontbreekt; aanvullende spraak/OCR-functies worden niet aangevraagd. |
| Systeemvoorkeur voor weergavetaal | en-US |
| Taal voor oudere, niet-Unicode-programma's | en-US |
| Uitvoerend gebruikersaccount | Engels eerst in de talenlijst; weergavetaal en standaardtoetsenbord worden ingesteld. Overige talen blijven beschikbaar. |
| Aanmeldscherm en systeemaccounts | Neemt de internationale instellingen van het uitvoerende account over. |
| Nieuwe gebruikers | Krijgen diezelfde instellingen als standaard. |
| Andere bestaande gebruikers | Hun persoonlijke taalvoorkeur wordt niet overschreven. Zij kunnen hun oude taal houden. |
| Regionale datum- en getalnotatie | Behoudt het bestaande formaat van het uitvoerende account door automatische afleiding uit de weergavetaal uit te schakelen. |
| Land/regio | Het uitvoerende account houdt zijn regio; kopieren naar systeemaccounts en nieuwe gebruikers neemt die regio mee. |
| Tijdzone | Blijft ongewijzigd. |

Gebruik een aangemeld gebruikersaccount met beheerrechten, niet `SYSTEM`.
Als je bij de UAC-vraag een ander administratoraccount invoert, is dat andere
account het uitvoerende account en de bron voor de te kopieren instellingen.
Windows 11 Pro wordt ondersteund; edities met slechts een toegestane
weergavetaal worden geweigerd. Het downloaden vereist toegang tot de
Windows-taalcomponenten; bedrijfsbeleid kan dat beperken.

Dit verandert niet de oorspronkelijke taal van installatie-/herstelmedia en
is geen beleid dat alle bestaande gebruikers blijvend tot Engels dwingt.
Andere geinstalleerde taalpakketten worden niet verwijderd. Bij een fout stopt
het script met exitcode `1`; al uitgevoerde instellingen worden niet automatisch
teruggedraaid. Na het oplossen van de fout kun je het script opnieuw uitvoeren.

Gebaseerd op de Microsoft-documentatie voor
[Install-Language](https://learn.microsoft.com/en-us/powershell/module/languagepackmanagement/install-language),
[Set-SystemPreferredUILanguage](https://learn.microsoft.com/en-us/powershell/module/languagepackmanagement/set-systempreferreduilanguage),
[Copy-UserInternationalSettingsToSystem](https://learn.microsoft.com/en-us/powershell/module/international/copy-userinternationalsettingstosystem)
en [toetsenbordcodes](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-language-pack-default-values).

## Publicatie

GitHub Pages publiceert vanuit de hoofdmap van `main`. `.nojekyll` zorgt dat
de bestanden als statische bestanden worden gepubliceerd.

De downloadlink volgt de huidige versie op `main`. Wijzigingen aan het script
worden na publicatie op dezelfde URL beschikbaar.

## Controle

Het Chrome-script is op syntax en `-WhatIf` gecontroleerd met Windows
PowerShell 5.1 en PowerShell 7. Het taalscript is bedoeld voor Windows
PowerShell 5.1: tien tests met gesimuleerde instellingscmdlets en echte
`-WhatIf`-runs voor beide toetsenborden zijn geslaagd. De gecontroleerde
taalinstellingen waren voor en na die proefruns gelijk. De scripts zijn niet
gebruikt om deze ontwikkel-pc te wijzigen;
een echte installatie/taalomzetting moet nog op een doel-pc worden gecontroleerd.

De tests staan in `tests/set-windows-english.Tests.ps1` en kunnen vanuit de
repositorymap in Windows PowerShell 5.1 met de meegeleverde Pester worden gestart:

```powershell
Invoke-Pester -Script .\tests\set-windows-english.Tests.ps1
```
