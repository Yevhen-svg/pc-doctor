# Запись игровых сессий.
# Пока идёт игра с включённым игровым профилем, раз в 2 секунды сохраняем температуры, загрузку, память, диск и пинг.
# После игры показываем, когда и почему система была перегружена.
# ВАЖНО: это НЕ счётчик FPS. Причины выводятся по состоянию системы, а не по кадрам.
# Запись по умолчанию выключена: во время игры программа читает датчики, а это нужно включать осознанно.

$script:Sess = $null
$script:SessProbe = [datetime]'2000-01-01'
$script:SessEvery = 2        # секунд между замерами
if ($env:PCD_SESS_EVERY -and [int]$env:PCD_SESS_EVERY -gt 0) { $script:SessEvery = [int]$env:PCD_SESS_EVERY }
$script:SessMax = 7200       # максимум замеров (около 4 часов)

function Sess-CfgPath { Join-Path $script:AppDir 'rec.json' }
function Sess-File { Join-Path $script:AppDir 'sessions.json' }
$script:SessEn = $null
function Sess-Enabled {
    if ($null -ne $script:SessEn) { return $script:SessEn }     # не читаем файл каждую секунду
    $v = $false
    $d = Json-Read (Sess-CfgPath) $null
    if ($d -and $d.PSObject.Properties['enabled']) { $v = [bool]$d.enabled }
    $script:SessEn = $v
    return $v
}
function Sess-SetEnabled($on) {
    $en = [bool]$on
    try { Json-Write (Sess-CfgPath) ([ordered]@{ enabled = $en }) } catch { return [ordered]@{ ok = $false; message = 'Не удалось сохранить настройку.' } }
    $script:SessEn = $en
    if (-not $en -and $script:Sess) { try { [void](Sess-End 'запись выключена') } catch { } }
    return [ordered]@{ ok = $true; enabled = $en }
}

function Sess-Num($v) {
    if ($null -eq $v) { return $null }
    try { return [double]$v } catch { return $null }
}
function Sess-Sample {
    $d = $null
    if (-not $script:MockMode -and $null -ne $script:cache -and ((Get-Date) - $script:cacheAt).TotalSeconds -lt 3) { $d = $script:cache }
    else { $d = Get-Live $script:Gateway $script:MockMode }
    if (-not $d) { return $null }
    $db = $null
    foreach ($k in @($d.disks)) { $b = Sess-Num $k.busy; if ($null -ne $b -and ($null -eq $db -or $b -gt $db)) { $db = $b } }
    $pg = $d.ping
    return [ordered]@{
        ct = (Sess-Num $d.cpu.temp); cl = (Sess-Num $d.cpu.load); cm = (Sess-Num $d.cpu.mhz)
        gt = (Sess-Num $d.gpu.temp); gl = (Sess-Num $d.gpu.load); rp = (Sess-Num $d.ram.pct); db = $db
        pg = (Sess-Num $pg.gw); pi = (Sess-Num $pg.isp); pw = (Sess-Num $pg.inet)
    }
}

function Sess-Begin($g) {
    if ($script:Sess) { return }
    if (-not (Sess-Enabled)) { return }
    $S = [ordered]@{ id = [guid]::NewGuid().ToString(); game = [string]$g.name; start = (Get-Date); last = [datetime]'2000-01-01'; lastT = 0; ck = (Get-Date); cols = [ordered]@{} }
    foreach ($k in 'ct', 'cl', 'cm', 'gt', 'gl', 'rp', 'db', 'pg', 'pi', 'pw') { $S.cols[$k] = New-Object System.Collections.ArrayList }
    $script:Sess = $S
}
function Sess-Tick {
    $S = $script:Sess
    if (-not $S) {
        # запись включили во время игры или программу перезапустили при идущей игре
        if (-not (Sess-Enabled)) { return }
        if (((Get-Date) - $script:SessProbe).TotalSeconds -lt 5) { return }
        $script:SessProbe = Get-Date
        $st = Games-Load
        if ($st.active) { Sess-Begin ([pscustomobject]@{ name = [string]$st.active.name }) }
        return
    }
    if (((Get-Date) - $S.last).TotalSeconds -lt $script:SessEvery) { return }
    $S.last = Get-Date
    $S.lastT = [math]::Round(((Get-Date) - $S.start).TotalSeconds, 1)
    $m = Sess-Sample
    if (-not $m) { return }
    foreach ($k in @($S.cols.Keys)) { [void]$S.cols[$k].Add($m[$k]) }
    if (((Get-Date) - $S.ck).TotalSeconds -ge 60) { $S.ck = Get-Date; Sess-Checkpoint }
    if ($S.cols['ct'].Count -ge $script:SessMax) { [void](Sess-End 'достигнут предел записи'); [void](Add-Event 'game' 'Запись сессии остановлена: достигнут предел (около 4 часов)' 'Игра продолжается, но дальше она не записывается.') }
}

function Sess-LivePath { Join-Path $script:AppDir 'sess-live.json' }
function Sess-WriteAtomic($path, $obj) {
    $tmp = $path + '.tmp'
    Json-Write $tmp $obj
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Sess-Checkpoint {
    # сырые данные на диск раз в минуту: если ПК завис или выключился, отчёт не пропадёт
    $S = $script:Sess; if (-not $S) { return }
    try {
        $cols = [ordered]@{}; foreach ($k in $S.cols.Keys) { $cols[$k] = @($S.cols[$k]) }
        Sess-WriteAtomic (Sess-LivePath) ([ordered]@{ id = $S.id; game = $S.game; start = $S.start.ToString('o'); lastT = $S.lastT; cols = $cols })
    } catch { }
}
function Sess-Recover {
    $p = Sess-LivePath
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $d = Json-Read $p $null
        if ($d -and $d.cols) {
            $S = [ordered]@{ id = [string]$d.id; game = [string]$d.game; start = [datetime]::Parse([string]$d.start, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind); lastT = [double]$d.lastT; cols = [ordered]@{} }
            foreach ($k in 'ct', 'cl', 'cm', 'gt', 'gl', 'rp', 'db', 'pg', 'pi', 'pw') {
                $al = New-Object System.Collections.ArrayList
                foreach ($v in @($d.cols.$k)) { [void]$al.Add($v) }
                $S.cols[$k] = $al
            }
            if ($S.cols['ct'].Count -ge 15 -and $S.lastT -ge 30) { [void](Sess-Save $S 'прервана: программа или ПК выключились во время игры') }
        }
    } catch { }
    try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }
}

# ---------- анализ ----------
function Sess-Vals($list) { return @(@($list) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }) }
function Sess-Max($list) { $v = Sess-Vals $list; if (-not $v.Count) { return $null }; return ($v | Measure-Object -Maximum).Maximum }
function Sess-Avg($list) { $v = Sess-Vals $list; if (-not $v.Count) { return $null }; return [math]::Round(($v | Measure-Object -Average).Average, 1) }
function Sess-Med($list) { $v = @(Sess-Vals $list | Sort-Object); if (-not $v.Count) { return $null }; return $v[[int][math]::Floor(($v.Count - 1) * 0.5)] }
function Sess-LossPct($list) {
    $a = @($list | Where-Object { $null -ne $_ }); if (-not $a.Count) { return $null }
    return [math]::Round(((@($a | Where-Object { [double]$_ -lt 0 }).Count) / $a.Count) * 100, 1)
}
function Sess-OkVals($list) { return @(Sess-Vals $list | Where-Object { $_ -ge 0 }) }

function Sess-Eps($flags, [int]$minLen) {
    # непрерывные отрезки, где условие выполняется; щель в один замер не разрывает отрезок
    $eps = @(); $start = -1; $gap = 0; $last = -1
    for ($i = 0; $i -lt $flags.Count; $i++) {
        if ($flags[$i]) { if ($start -lt 0) { $start = $i }; $last = $i; $gap = 0 }
        elseif ($start -ge 0) {
            $gap++
            if ($gap -gt 1) { if (($last - $start + 1) -ge $minLen) { $eps += , @($start, $last) }; $start = -1; $gap = 0 }
        }
    }
    if ($start -ge 0 -and ($last - $start + 1) -ge $minLen) { $eps += , @($start, $last) }
    return , $eps
}
function Sess-Flags($vals, [scriptblock]$cond) {
    $o = New-Object 'bool[]' $vals.Count
    for ($i = 0; $i -lt $vals.Count; $i++) { $v = $vals[$i]; if ($null -ne $v) { $o[$i] = [bool](& $cond ([double]$v)) } }
    return , $o
}
function Sess-Down($list, [int]$pts, [string]$mode) {
    $n = $list.Count; if ($n -eq 0) { return , @() }
    $step = [math]::Max(1, [int][math]::Ceiling($n / $pts))
    $out = @()
    for ($i = 0; $i -lt $n; $i += $step) {
        $b = @(); $lostN = 0
        for ($j = $i; $j -lt [math]::Min($n, $i + $step); $j++) { if ($null -ne $list[$j]) { if ([double]$list[$j] -lt 0) { $lostN++ } else { $b += [double]$list[$j] } } }
        if ($mode -eq 'ping' -and $lostN -gt 0 -and $lostN -ge $b.Count) { $out += -1 }
        elseif (-not $b.Count) { $out += $null }
        elseif ($mode -eq 'avg') { $out += [math]::Round(($b | Measure-Object -Average).Average, 1) }
        else { $out += [math]::Round(($b | Measure-Object -Maximum).Maximum, 1) }
    }
    return , $out
}

function Sess-Slice($list, [int]$a, [int]$b) {
    $l = @($list); if ($a -lt 0) { $a = 0 }; if ($b -ge $l.Count) { $b = $l.Count - 1 }
    if ($b -lt $a) { return , @() }
    return , @($l[$a..$b])
}
function Sess-Drift($c, [int]$n) {
    # сравнение первых и последних 20 % записи: что "поплыло" к концу игры
    if ($n -lt 60) { return @() }
    $k = [math]::Max(15, [int][math]::Floor($n * 0.2))
    $out = @()
    $defs = @(
        @{ key = 'ct'; label = 'Температура процессора'; unit = '°C'; min = 8; hint = 'Процессор нагрелся к концу игры. Проверьте охлаждение, если температура поднимается выше 85–90 °C.' },
        @{ key = 'gt'; label = 'Температура видеокарты'; unit = '°C'; min = 8; hint = 'Видеокарта нагрелась к концу игры. Проверьте охлаждение, если температура поднимается выше 80–85 °C.' },
        @{ key = 'cl'; label = 'Загрузка процессора'; unit = '%'; min = 15; hint = 'Загрузка процессора выросла к концу игры. Возможно, в фоне что-то запустилось: загрузка, обновление, запись.' },
        @{ key = 'rp'; label = 'Занятая память'; unit = '%'; min = 8; hint = 'Память заполнялась по ходу игры. Если она подходит к 90 % и выше, закройте браузер и лишние программы. Постоянный рост может говорить об утечке памяти в игре.' }
    )
    foreach ($d in $defs) {
        $f = Sess-Avg (Sess-Slice $c[$d.key] 0 ($k - 1)); $l = Sess-Avg (Sess-Slice $c[$d.key] ($n - $k) ($n - 1))
        if ($null -ne $f -and $null -ne $l -and (($l - $f) -ge $d.min)) {
            $out += [ordered]@{ key = $d.key; label = $d.label; from = [math]::Round($f, 0); to = [math]::Round($l, 0); unit = $d.unit; hint = $d.hint }
        }
    }
    $f = Sess-Avg (Sess-Slice $c['cm'] 0 ($k - 1)); $l = Sess-Avg (Sess-Slice $c['cm'] ($n - $k) ($n - 1))
    if ($null -ne $f -and $null -ne $l -and $f -gt 0 -and ((($f - $l) / $f) -ge 0.08)) {
        $out += [ordered]@{ key = 'cm'; label = 'Частота процессора'; from = [math]::Round($f, 0); to = [math]::Round($l, 0); unit = 'МГц'; hint = 'Частота процессора упала к концу игры. Если одновременно выросла температура, это похоже на снижение частоты из-за нагрева.' }
    }
    foreach ($d in @(@{ key = 'pg'; label = 'Пинг до роутера'; hint = 'Пинг до роутера вырос к концу игры. Возможны помехи Wi‑Fi или перегрузка канала.' }, @{ key = 'pw'; label = 'Пинг до интернета'; hint = 'Пинг до интернета вырос к концу игры. Возможно, дело в провайдере или сервере игры.' })) {
        $f = Sess-Med (Sess-OkVals (Sess-Slice $c[$d.key] 0 ($k - 1))); $l = Sess-Med (Sess-OkVals (Sess-Slice $c[$d.key] ($n - $k) ($n - 1)))
        if ($null -ne $f -and $null -ne $l -and (($l - $f) -ge 15) -and ($l -ge ($f * 1.5))) {
            $out += [ordered]@{ key = $d.key; label = $d.label; from = [math]::Round($f, 0); to = [math]::Round($l, 0); unit = 'мс'; hint = $d.hint }
        }
    }
    return @($out)
}

function Sess-Analyze($S) {
    $c = $S.cols; $n = $c['ct'].Count
    $ev = $script:SessEvery; if ($n -gt 1 -and $S.lastT -gt 0) { $ev = [double]$S.lastT / $n }
    $okShare = { param($l) $a = @($l); if (-not $a.Count) { return 0 }; return (@($a | Where-Object { $null -ne $_ }).Count / $a.Count) }
    $tempNo = (((& $okShare $c['ct']) -lt 0.5) -and ((& $okShare $c['gt']) -lt 0.5))
    $gwLoss = Sess-LossPct $c['pg']; $gwBlind = ($null -eq $gwLoss) -or ($gwLoss -gt 90)
    $events = @()
    $addEps = {
        param($kind, $fault, $title, $tip, $eps, $vals, $fmt)
        $events = @()
        foreach ($e in $eps) {
            $seg = @(); for ($i = $e[0]; $i -le $e[1]; $i++) { $seg += , $vals[$i] }
            $events += [ordered]@{ kind = $kind; fault = $fault; title = $title; detail = (& $fmt $seg); tip = $tip; startSec = [int][math]::Round($e[0] * $ev); durSec = [int][math]::Max(1, [math]::Round(($e[1] - $e[0] + 1) * $ev)) }
        }
        return $events
    }
    $mx = { param($seg) $m = Sess-Max $seg; if ($null -eq $m) { 0 } else { [int][math]::Round($m) } }
    $events += @(& $addEps 'cpu_hot' $true 'Перегрев процессора' 'Проверьте охлаждение: пыль, кулер, термопасту, приток воздуха в корпусе. Можно поднять обороты вентиляторов.' (Sess-Eps (Sess-Flags $c['ct'] { param($v) $v -ge 90 }) 3) $c['ct'] { param($s) 'до ' + (& $mx $s) + ' °C' })
    $events += @(& $addEps 'gpu_hot' $true 'Перегрев видеокарты' 'Проверьте охлаждение видеокарты и приток воздуха. Видеокарта сама снижает частоту при перегреве, и FPS падает.' (Sess-Eps (Sess-Flags $c['gt'] { param($v) $v -ge 85 }) 3) $c['gt'] { param($s) 'до ' + (& $mx $s) + ' °C' })
    $events += @(& $addEps 'ram_full' $true 'Почти кончилась оперативная память' 'Закройте браузер и лишние программы. Если памяти мало постоянно, помогает добавить планку.' (Sess-Eps (Sess-Flags $c['rp'] { param($v) $v -ge 92 }) 3) $c['rp'] { param($s) 'занято до ' + (& $mx $s) + ' %' })
    $events += @(& $addEps 'disk_busy' $true 'Диск загружен почти на 100 %' 'Игра или программа в фоне подгружает данные. Помогает SSD и закрытие фоновых загрузок и обновлений.' (Sess-Eps (Sess-Flags $c['db'] { param($v) $v -ge 90 }) 10) $c['db'] { param($s) 'до ' + (& $mx $s) + ' %' })
    $events += @(& $addEps 'cpu_bound' $false 'Процессор загружен почти полностью' 'В это время FPS ограничивал процессор, а не видеокарта. Помогает закрыть фоновые программы и более быстрый процессор.' (Sess-Eps (Sess-Flags $c['cl'] { param($v) $v -ge 95 }) 5) $c['cl'] { param($s) 'в среднем ' + [int][math]::Round((Sess-Avg $s)) + ' %' })
    # сеть: скачок до роутера; скачок до интернета учитываем, только когда роутер в это время в порядке
    $pgv = @($c['pg']); $pwv = @($c['pw'])
    $netFmt = { param($s) $o = @(Sess-OkVals $s); $m = $(if ($o.Count) { [int][math]::Round(($o | Measure-Object -Maximum).Maximum) } else { 0 }); $loss = (@(Sess-Vals $s | Where-Object { $_ -lt 0 }).Count -gt 0); $(if ($loss -and -not $o.Count) { 'пакеты не проходили' } elseif ($loss) { 'потери пакетов, пики до ' + $m + ' мс' } else { 'пики до ' + $m + ' мс' }) }
    $homeEps = @(); if (-not $gwBlind) { $homeEps = (Sess-Eps (Sess-Flags $pgv { param($v) $v -lt 0 -or $v -ge 80 }) 2) }
    $events += @(& $addEps 'net_home' $true 'Сбой связи с роутером' 'Wi‑Fi или роутер. Подключитесь кабелем или подойдите ближе к роутеру.' $homeEps $pgv $netFmt)
    $farFlags = New-Object 'bool[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $gwOk = ($null -ne $pgv[$i]) -and ([double]$pgv[$i] -ge 0) -and ([double]$pgv[$i] -lt 80)
        if ($gwOk -and $null -ne $pwv[$i]) { $farFlags[$i] = ([double]$pwv[$i] -lt 0) -or ([double]$pwv[$i] -ge 200) }
    }
    $events += @(& $addEps 'net_far' $true 'Сбой связи дальше роутера' 'Дома связь ровная, значит, проблема у провайдера или на сервере игры.' (Sess-Eps $farFlags 2) $pwv $netFmt)
    if ($gwBlind) { $farFlags = New-Object 'bool[]' $n; $events = @($events | Where-Object { $_.kind -ne 'net_far' }) }
    if ($events.Count -gt 50) { $events = @($events | Sort-Object { $_.durSec } -Descending | Select-Object -First 50) }
    $events = @($events | Sort-Object { $_.startSec })

    # итоговая сводка
    $sum = [ordered]@{
        ctMax = (Sess-Max $c['ct']); ctAvg = (Sess-Avg $c['ct']); gtMax = (Sess-Max $c['gt']); gtAvg = (Sess-Avg $c['gt'])
        clAvg = (Sess-Avg $c['cl']); rpMax = (Sess-Max $c['rp']); dbMax = (Sess-Max $c['db'])
        pgMed = (Sess-Med (Sess-OkVals $c['pg'])); pgMax = (Sess-Max (Sess-OkVals $c['pg'])); pgLoss = (Sess-LossPct $c['pg'])
        pwMed = (Sess-Med (Sess-OkVals $c['pw'])); pwMax = (Sess-Max (Sess-OkVals $c['pw'])); pwLoss = (Sess-LossPct $c['pw'])
    }
    # вердикт: что чаще всего мешало (по суммарному времени)
    $faults = @($events | Where-Object { $_.fault })
    $verdict = $null
    if ($faults.Count -eq 0 -and ($tempNo -or $gwBlind)) {
        $miss = @(); if ($tempNo) { $miss += 'температуры (нужен запуск от администратора, а для видеокарт не NVIDIA датчик может быть недоступен)' }; if ($gwBlind) { $miss += 'пинг до роутера (роутер не отвечает на пинг: многие так настроены, или адрес определился неверно)' }
        $verdict = [ordered]@{ code = 'nodata'; title = 'Часть данных измерить не удалось'; text = ('Не измерено: ' + ($miss -join '; ') + '. Поэтому «всё в порядке» сказать нельзя: по остальным показателям (память, диск, загрузка) проблем нет.') }
    } elseif ($faults.Count -eq 0) {
        $bound = @($events | Where-Object { $_.kind -eq 'cpu_bound' } | ForEach-Object { $_.durSec } | Measure-Object -Sum).Sum
        $totalSec = $n * $ev
        if ($bound -and $totalSec -gt 0 -and ($bound / $totalSec) -ge 0.3) {
            $verdict = [ordered]@{ code = 'cpubound'; title = 'Перегрева и сбоев не было, но процессор был перегружен'; text = 'Значительную часть времени процессор был загружен почти полностью, поэтому в этой игре FPS ограничивает он. Это не поломка, это предел железа.' }
        } else {
            $verdict = [ordered]@{ code = 'clean'; title = 'Ничего подозрительного не нашёл'; text = 'Перегрева, нехватки памяти, перегрузки диска и сбоев сети не было. Если игра лагала, причина, скорее всего, в самой игре, её сервере или драйвере видеокарты.' }
        }
    } else {
        $groups = $faults | Group-Object { $_.kind } | ForEach-Object { [pscustomobject]@{ kind = $_.Name; sec = (($_.Group | ForEach-Object { $_.durSec } | Measure-Object -Sum).Sum); cnt = $_.Count; ev = $_.Group[0] } } | Sort-Object { $_.sec } -Descending
        $top = $groups | Select-Object -First 1
        $mins = [math]::Round($top.sec / 60, 1)
        $verdict = [ordered]@{ code = [string]$top.kind; title = ('Чаще всего мешало: ' + ([string]$top.ev.title).ToLower()); text = ('Случаев: ' + $top.cnt + ', суммарно около ' + $mins + ' мин. ' + [string]$top.ev.tip) }
    }
    $pts = 240
    $step = [math]::Max(1, [int][math]::Ceiling($n / $pts))
    return [ordered]@{
        id = $S.id; game = $S.game; start = ($S.start).ToString('yyyy-MM-dd HH:mm:ss'); durationSec = [int][math]::Round($n * $ev); samples = $n
        summary = $sum; events = @($events); verdict = $verdict; drift = @(Sess-Drift $c $n)
        series = [ordered]@{ stepSec = [int][math]::Round($step * $ev)
            ct = (Sess-Down $c['ct'] $pts 'max'); gt = (Sess-Down $c['gt'] $pts 'max'); rp = (Sess-Down $c['rp'] $pts 'max')
            cl = (Sess-Down $c['cl'] $pts 'avg'); pg = (Sess-Down $c['pg'] $pts 'ping'); pw = (Sess-Down $c['pw'] $pts 'ping') }
    }
}

function Sess-Save($S, $reason) {
    $rep = Sess-Analyze $S
    if ($reason -and $reason -like 'прервана*') { $rep.verdict.text = ('Сессия оборвалась (' + $reason + '), показаны данные до последнего сохранения. ' + $rep.verdict.text) }
    $all = @(Json-Read (Sess-File) @())
    $all += $rep
    if ($all.Count -gt 10) { $all = @($all | Select-Object -Last 10) }
    Sess-WriteAtomic (Sess-File) $all
    [void](Add-Event 'game' ('Отчёт игровой сессии готов: ' + $S.game) ([string]$rep.verdict.title))
    return $rep
}
function Sess-End($reason) {
    $S = $script:Sess
    if (-not $S) { return $null }
    $script:Sess = $null
    $S.lastT = [math]::Round(((Get-Date) - $S.start).TotalSeconds, 1)
    try { Remove-Item -LiteralPath (Sess-LivePath) -Force -ErrorAction SilentlyContinue } catch { }
    if ($S.cols['ct'].Count -lt 15 -or $S.lastT -lt 30) { return $null }     # слишком коротко, отчёт не нужен
    try { return (Sess-Save $S $null) }
    catch {
        # не теряем сырые данные: кладём рядом и сообщаем
        try { Sess-Checkpoint2 $S } catch { }
        try { [void](Add-Event 'game' ('Не удалось сохранить отчёт сессии: ' + $S.game) ([string]$_.Exception.Message)) } catch { }
        return $null
    }
}
function Sess-Checkpoint2($S) {
    $cols = [ordered]@{}; foreach ($k in $S.cols.Keys) { $cols[$k] = @($S.cols[$k]) }
    Sess-WriteAtomic (Sess-LivePath) ([ordered]@{ id = $S.id; game = $S.game; start = $S.start.ToString('o'); lastT = $S.lastT; cols = $cols })
}

function Sess-Status {
    $act = $null
    if ($script:Sess) { $act = [ordered]@{ game = $script:Sess.game; samples = $script:Sess.cols['ct'].Count; elapsedSec = [int]((Get-Date) - $script:Sess.start).TotalSeconds } }
    $items = @()
    try {
        $fi = Get-Item -LiteralPath (Sess-File) -ErrorAction Stop
        $stamp = [string]$fi.LastWriteTimeUtc.Ticks + ':' + [string]$fi.Length
        if ($script:SessItemsStamp -ne $stamp) { $script:SessItems = @(Json-Read (Sess-File) @()); $script:SessItemsStamp = $stamp }
        $items = $script:SessItems
    } catch { $script:SessItems = @(); $script:SessItemsStamp = '' }
    return [ordered]@{ enabled = (Sess-Enabled); active = $act; items = $items }
}
function Sess-Delete($id) {
    $all = @(Json-Read (Sess-File) @() | Where-Object { [string]$_.id -ne [string]$id })
    try { Sess-WriteAtomic (Sess-File) $all } catch { return [ordered]@{ ok = $false } }
    return [ordered]@{ ok = $true }
}

# Очистка данных из страницы «Настройки»: только журнал событий и отчёты сессий (история отката не трогается).
function Clear-AppData($what) {
    try {
        if ($what -eq 'events') { $f = Events-Path }
        elseif ($what -eq 'sessions') { $f = Sess-File }
        else { return [ordered]@{ ok = $false } }
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
        return [ordered]@{ ok = $true }
    } catch { return [ordered]@{ ok = $false } }
}
