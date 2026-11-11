# WhatsApp Vinted Monitor - GitHub Actions (cloud, 24/7) — versione SEPARATA via WhatsApp
# Ricerche identiche alla versione Telegram, ma gli avvisi arrivano via WhatsApp (CallMeBot).
# Numero telefono + apikey vengono letti dal repo PRIVATO "vinted-whatsapp-config" (config.json),
# che l'app Android "WhatsApp Vinted" può aggiornare in qualsiasi momento.

$ErrorActionPreference = "Stop"

$Searches = @(
    @{ term = "21302" },
    @{ term = "76352" },
    @{ term = "31199" }
)
$StateFile = "./ws-vinted-state.json"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
$ConfigRepo = "Oscuro86Bad/vinted-whatsapp-config"

function Write-Log { param([string]$m); Write-Output $m }

function Get-WaConfig {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$ConfigRepo/contents/config.json" -Headers @{
            Authorization = "token $env:TRIGGER_TOKEN"
            Accept        = "application/vnd.github+json"
            "User-Agent"  = "ws-vinted-monitor"
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

Write-Log "--- Vinted scan WhatsApp $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

$foundItems = @{}
$termIds = @{}   # termine di ricerca -> ids di quell'annuncio in quella ricerca

foreach ($s in $Searches) {
    try {
        $url = "https://www.vinted.it/catalog?search_text=$([uri]::EscapeDataString($s.term))"
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA } -UseBasicParsing -TimeoutSec 60
        $c = $resp.Content
        $anchors = [regex]::Matches($c, 'data-testid="product-item-id-(\d+)"')
        foreach ($a in $anchors) {
            $id = $a.Groups[1].Value
            if (-not $termIds.ContainsKey($s.term)) { $termIds[$s.term] = @() }
            if ($foundItems.ContainsKey($id)) {
                if ($termIds[$s.term] -notcontains $id) { $termIds[$s.term] = @($termIds[$s.term]) + $id }
                continue
            }
            $winSize = [Math]::Min(4000, $c.Length - $a.Index)
            $win = $c.Substring($a.Index, $winSize)
            $t = [regex]::Match($win, 'alt="([^"]{5,200})"')
            if (-not $t.Success) { continue }
            $alt = $t.Groups[1].Value
            $titolo = ($alt -split ',\s*(?:Condizioni|Marca|Brand)').Trim()
            $prezzo = [regex]::Match($alt, '(\d{1,6}[\.,]\d{2})').Groups[1].Value
            $foundItems[$id] = @{ title = $titolo; price = $prezzo }
            $termIds[$s.term] = @($termIds[$s.term]) + $id
        }
        Write-Log "Ricerca '$($s.term)': $($anchors.Count) item."
    } catch {
        Write-Log "ERRORE ricerca '$($s.term)': $($_.Exception.Message)"
    }
}

$allIds = @($foundItems.Keys)
Write-Log "Totale item validi: $($allIds.Count)"

# ---- Baseline primo run: registra e non notifica ----
if (-not (Test-Path $StateFile)) {
    @{ seenIds = $allIds; baselinedTerms = @($Searches | ForEach-Object { $_.term }) } |
        ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline salvata: $($allIds.Count) annunci gia' online, nessuna notifica."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
$known = @($state.seenIds)
$baselined = @($state.baselinedTerms)
if (-not $state.baselinedTerms) { $baselined = @() }

$notifiedCount = 0
foreach ($s in $Searches) {
    $term = $s.term
    $ids = @(); if ($termIds.ContainsKey($term)) { $ids = @($termIds[$term]) }
    if ($baselined -contains $term) {
        $news = @($ids | Where-Object { $known -notcontains $_ })
        if ($news.Count -gt 0) {
            # CLAIM ANTICIPATO anti-doppio
            $known = @($known) + @($news)
            @{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
        }
        foreach ($id in $news) {
            $it = $foundItems[$id]
            $msg = "*Nuovo annuncio Vinted* ($term): $($it.title)`nPrezzo: $($it.price) euro`nhttps://www.vinted.it/items/$id"
            $sent = Send-WhatsApp $msg
            if ($sent) {
                $notifiedCount++
                Write-Log "Notificato $id ($term)"
            } else {
                $known = @($known | Where-Object { $_ -ne $id })
                @{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
            }
        }
    } else {
        foreach ($id in $ids) { if ($known -notcontains $id) { $known += $id } }
        $baselined += $term
        Write-Log "Baseline silenziosa per '$term': $($ids.Count) annunci registrati senza notifiche."
    }
}

if ($known.Count -gt 800) { $known = $known | Select-Object -Last 800 }
@{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
Write-Log "Stato aggiornato: $($known.Count) id in memoria. Notificati in questo giro: $notifiedCount."
