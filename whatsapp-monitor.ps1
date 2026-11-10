# WhatsApp LEGO Restock Monitor - GitHub Actions (versione SEPARATA via WhatsApp)
# Controlla la disponibilita' del set 76294 su LEGO.com Shop IT
# e invia un messaggio WhatsApp quando torna acquistabile (via CallMeBot).
# Numero + apikey letti dal repo PRIVATO "vinted-whatsapp-config" (config.json).

$ErrorActionPreference = "Stop"

$ProductSlug = "x-men-the-x-mansion-76294"
$ProductUrl  = "https://www.lego.com/it-it/product/$ProductSlug"
$StateFile   = "./ws-lego-state.json"
$ConfigRepo  = "Oscuro86Bad/vinted-whatsapp-config"

function Write-Log { param([string]$m); Write-Output $m }

function Get-WaConfig {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$ConfigRepo/contents/config.json" -Headers @{
            Authorization = "token $env:TRIGGER_TOKEN"
            Accept        = "application/vnd.github+json"
            "User-Agent"  = "ws-lego-monitor"
        } -TimeoutSec 30
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace "\s", "")))
        return $json | ConvertFrom-Json
    } catch {
        Write-Log "ERRORE lettura config: $($_.Exception.Message)"
        return $null
    }
}

function Send-WhatsApp {
    param([string]$Text)
    if (-not $env:TRIGGER_TOKEN) { Write-Log "TRIGGER_TOKEN mancante."; return $false }
    $cfg = Get-WaConfig
    if (-not $cfg -or -not $cfg.phone -or -not $cfg.apikey) {
        Write-Log "WhatsApp non configurato: imposta numero+apikey dall'app. Notifica saltata."
        return $false
    }
    $url = "https://api.callmebot.com/whatsapp.php?phone=$([uri]::EscapeDataString([string]$cfg.phone))&text=$([uri]::EscapeDataString($Text))&apikey=$([uri]::EscapeDataString([string]$cfg.apikey))"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
        if ($resp.StatusCode -eq 200) {
            Write-Log "WhatsApp inviato."
            return $true
        }
        Write-Log ("CallMeBot HTTP " + $resp.StatusCode)
        return $false
    } catch {
        Write-Log "ERRORE invio WhatsApp: $($_.Exception.Message)"
        return $false
    }
}

Write-Log "--- Controllo $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# Modalita' test: invia messaggio di prova via WhatsApp ed esce
if ($env:TEST_MESSAGE -eq "true") {
    $sent = Send-WhatsApp "TEST invio WhatsApp: il monitoraggio LEGO (76294 X-Men: X-Mansion) e' attivo e funzionante. Quando il set torna disponibile, riceverai l'avviso qui."
    if ($sent) { Write-Log "TEST MESSAGE INVIATO CORRETTAMENTE." } else { Write-Log "TEST MESSAGE: invio fallito, controllare config." }
    exit 0
}

$query = @"
{ product(slug: "$ProductSlug") {
  name
  ... on SingleVariantProduct {
    variant {
      price { formattedAmount }
      attributes { availabilityStatus availabilityText canAddToBag }
    }
  }
} }
"@

$payload = @{ query = $query } | ConvertTo-Json -Depth 5

try {
    $headers = @{
        "Content-Type" = "application/json"
        "User-Agent"   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
        "Origin"       = "https://www.lego.com"
        "Referer"      = $ProductUrl
        "x-locale"     = "it-IT"
    }
    $response = Invoke-RestMethod -Uri "https://www.lego.com/api/graphql/Product" -Method Post -Headers $headers -Body $payload -TimeoutSec 60
    $v     = $response.data.product.variant
    $attrs = $v.attributes
    $name  = $response.data.product.name
    $canBuy = [bool]$attrs.canAddToBag
    Write-Log "Stato: $($attrs.availabilityStatus) | $($attrs.availabilityText) | canAddToBag: $canBuy | prezzo: $($v.price.formattedAmount)"
} catch {
    Write-Log "ERRORE interrogazione LEGO.com: $($_.Exception.Message)"
    exit 0
}

# Baseline: primo run (nessuno stato salvato) => salva e non avvisa
if (-not (Test-Path $StateFile)) {
    @{ alerted = $false } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline iniziale salvata."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json

if ($canBuy -and -not $state.alerted) {
    # CLAIM ANTICIPATO anti-doppio
    @{ alerted = $true } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    $msg = "*GREAT NEWS!* Il set LEGO *$name (76294)* e' tornato disponibile!"
    $msg += "`nPrezzo: $($v.price.formattedAmount)"
    $msg += "`n$ProductUrl"
    $sent = Send-WhatsApp $msg
    if ($sent) {
        Write-Log "AVVISO INVIATO."
    } else {
        @{ alerted = $false } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
        Write-Log "Invio fallito: ritento al prossimo ciclo."
    }
    exit 0
}

if (-not $canBuy -and $state.alerted) {
    @{ alerted = $false } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Stato tornato indisponibile: notifica riarmata."
    exit 0
}

Write-Log "Nessun cambiamento ($($attrs.availabilityStatus))."
