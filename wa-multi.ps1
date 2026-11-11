# WhatsApp Multi-Device Monitor - GitHub Actions (cloud, 24/7)
# PER OGNI dispositivo (configs/<deviceId>.json nel repo PRIVATO vinted-whatsapp-config):
#   - esegue le TUE ricerche su Vinted
#   - confronta con lo stato SOLO tuo (state/<deviceId>.json, nello stesso repo)
#   - notifica i NUOVI annunci via WhatsApp (CallMeBot) SOLO al numero collegato
# Baseline silenziosa per dispositivi/chiavi nuove: nessuno spam.
# Nessuna dipendenza dal monitor Telegram (lego-restock-monitor) o dall'app principale.

$ErrorActionPreference = "Stop"

$ConfigRepo = "Oscuro86Bad/vinted-whatsapp-config"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
$Headers = @{
    Authorization = "token $env:TRIGGER_TOKEN"
    "User-Agent"  = "wa-multi-monitor"
    Accept        = "application/vnd.github+json"
}

function Write-Log { param([string]$m); Write-Output $m }

function GhGet([string]$path) {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$ConfigRepo/contents/$path" -Headers $Headers -TimeoutSec 30
}

function GhGetJson([string]$path) {
    $r = GhGet $path
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace "\s", "")))
    return @{ sha = $r.sha; obj = ($json | ConvertFrom-Json) }
}

function GhPutJson([string]$path, $obj, [string]$sha) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5)))
    $body = @{ message = "stato $path (wa-multi)"; content = $b64; branch = "main" }
    if ($sha) { $body.sha = $sha }
    $h = $Headers + @{ "Content-Type" = "application/json" }
    Invoke-RestMethod -Method Put -Uri "https://api.github.com/repos/$ConfigRepo/contents/$path" -Headers $h -Body ($body | ConvertTo-Json) -TimeoutSec 30 | Out-Null
}

function Send-WhatsApp {
    param([string]$Phone, [string]$Apikey, [string]$Text)
    $url = "https://api.callmebot.com/whatsapp.php?phone=$([uri]::EscapeDataString([string]$Phone))&text=$([uri]::EscapeDataString($Text))&apikey=$([uri]::EscapeDataString([string]$Apikey))"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
        return ($resp.StatusCode -eq 200)
    } catch {
        Write-Log "ERRORE invio WhatsApp: $($_.Exception.Message)"
        return $false
    }
}

Write-Log "--- WhatsApp multi scan $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

try {
    $listing = GhGet "configs"
} catch {
    Write-Log "Nessuna cartella configs o errore: $($_.Exception.Message)"
    exit 0
}

$devices = @($listing | Where-Object { $_.type -eq "file" -and $_.name -match '\.json$' })
Write-Log "Dispositivi configurati: $($devices.Count)"

foreach ($dev in $devices) {
    $deviceName = $dev.name -replace '\.json$', ''
    try {
        $cfgJ = GhGetJson "configs/$($dev.name)"
        $cfg = $cfgJ.obj
        $label = if ($cfg.label) { $cfg.label } else { $deviceName }
        if (-not $cfg.phone -or -not $cfg.apikey -or -not $cfg.searches -or @($cfg.searches).Count -eq 0) {
            Write-Log "Skip '$label' ($($dev.name)): telefono/apikey/ricerche mancanti."
            continue
        }
        Write-Log "Dispositivo '$label': $(@($cfg.searches).Count) ricerche."

        # ---- stato del dispositivo ----
        $statePath = "state/$($dev.name)"
        $known = @()
        $baselined = @()
        $cooldownUntil = $null
        $stateSha = $null
        $fresh = $true
        try {
            $sj = GhGetJson $statePath
            $stateSha = $sj.sha
            $known = @($sj.obj.seenIds)
            $baselined = @($sj.obj.baselinedTerms)
            if (-not $baselined) { $baselined = @() }
            if ($sj.obj.cooldownUntil) { $cooldownUntil = [datetime]$sj.obj.cooldownUntil }
            $fresh = $false
        } catch { }

        # ---- cooldown CallMeBot: dopo un rifiuto aspetta, non martellare ----
        if ($cooldownUntil -and $cooldownUntil -gt (Get-Date).ToUniversalTime()) {
            Write-Log "Cooldown '$label' fino a $($cooldownUntil.ToString('u')) (limite CallMeBot): giro in sola lettura."
            continue
        }

        # ---- scansione Vinted per le ricerche del dispositivo ----
        $foundItems = @{}
        $termIds = @{}
        foreach ($s in @($cfg.searches)) {
            $term = $s.term
            if (-not $term) { continue }
            if (-not $termIds.ContainsKey($term)) { $termIds[$term] = @() }
            try {
                $url = "https://www.vinted.it/catalog?search_text=$([uri]::EscapeDataString($term))"
                $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA } -UseBasicParsing -TimeoutSec 60
                $c = $resp.Content
                $anchors = [regex]::Matches($c, 'data-testid="product-item-id-(\d+)"')
                foreach ($a in $anchors) {
                    $id = $a.Groups[1].Value
                    if ($foundItems.ContainsKey($id)) {
                        if ($termIds[$term] -notcontains $id) { $termIds[$term] = @($termIds[$term]) + $id }
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
                    $termIds[$term] = @($termIds[$term]) + $id
                }
                Write-Log "'$label' ricerca '$term': $($anchors.Count) item."
            } catch {
                Write-Log "ERRORE ricerca '$term' ('$label'): $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }

        $dirty = $false

        # ---- primo giro di un dispositivo: baseline silenziosa ----
        if ($fresh) {
            foreach ($id in @($foundItems.Keys)) { $known += $id }
            foreach ($s in @($cfg.searches)) { if ($s.term) { $baselined += $s.term } }
            $dirty = $true
            Write-Log "Baseline silenziosa '$label': $(@($foundItems.Keys).Count) annunci registrati senza notifiche."
        } else {
            foreach ($s in @($cfg.searches)) {
                $term = $s.term
                if (-not $term) { continue }
                $ids = @(); if ($termIds.ContainsKey($term)) { $ids = @($termIds[$term]) }
                if ($baselined -notcontains $term) {
                    # NUOVA chiave per questo dispositivo: registra senza notificare
                    foreach ($id in $ids) { if ($known -notcontains $id) { $known += $id } }
                    $baselined += $term
                    $dirty = $true
                    Write-Log "Baseline silenziosa '$label' per '$term': $($ids.Count) annunci."
                    continue
                }
                $news = @($ids | Where-Object { $known -notcontains $_ })
                if ($news.Count -gt 0) {
                    # CLAIM ANTICIPATO anti-doppio
                    $known = @($known) + @($news)
                    $dirty = $true
                    # UN SOLO messaggio per termine (CallMeBot gratuito limita i messaggi ravvicinati):
                    # elenco fino a 5 annunci + "+N altri"
                    $msg = "*Nuovi annunci Vinted* ($term): $($news.Count) novita'"
                    $mostra = @($news | Select-Object -First 5)
                    foreach ($id in $mostra) {
                        $it = $foundItems[$id]
                        $msg += "`n- $($it.title) - $($it.price) euro`nhttps://www.vinted.it/items/$id"
                    }
                    if ($news.Count -gt $mostra.Count) { $msg += "`n+ altri $($news.Count - $mostra.Count) annunci nuovi" }
                    $sent = Send-WhatsApp -Phone $cfg.phone -Apikey $cfg.apikey -Text $msg
                    if ($sent) {
                        Write-Log "Notificati $($news.Count) annunci a '$label' ($term) in un messaggio."
                        $cooldownUntil = $null
                        Start-Sleep -Seconds 4   # distacco tra messaggi CallMeBot
                    } else {
                        # invio fallito (spesso limite CallMeBot 48 msg/4h): cooldown 25 min,
                        # gli annunci restano senza claim e si riprova dopo la pausa
                        $known = @($known | Where-Object { $news -notcontains $_ })
                        $cooldownUntil = (Get-Date).ToUniversalTime().AddMinutes(25)
                        $dirty = $true
                        Write-Log "Invio FALLITO ($($news.Count) annunci) a '$label' ($term): cooldown fino a $($cooldownUntil.ToString('u'))."
                    }
                }
            }
        }

        # ---- salva lo stato solo se e' cambiato (evita commit inutili) ----
        if ($dirty) {
            if ($known.Count -gt 800) { $known = @($known | Select-Object -Last 800) }
            $out = @{ seenIds = @($known); baselinedTerms = @($baselined) }
            if ($cooldownUntil) { $out.cooldownUntil = $cooldownUntil.ToString("o") }
            GhPutJson -path $statePath -obj $out -sha $stateSha
            Write-Log "Stato '$label' salvato ($($known.Count) id)."
        }
    } catch {
        Write-Log "ERRORE dispositivo '$($dev.name)': $($_.Exception.Message)"
    }
}

Write-Log "--- Scan completato ---"
