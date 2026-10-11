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

## Publicatie

GitHub Pages publiceert vanuit de hoofdmap van `main`. `.nojekyll` zorgt dat
de bestanden als statische bestanden worden gepubliceerd.

De downloadlink volgt de huidige versie op `main`. Wijzigingen aan het script
worden na publicatie op dezelfde URL beschikbaar.

## Controle

De PowerShell-syntax en `-WhatIf`-uitvoering zijn lokaal gecontroleerd met
Windows PowerShell 5.1 en PowerShell 7. Een echte Chrome-installatie moet nog
op een doel-pc worden uitgevoerd.
