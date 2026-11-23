# PC Doctor: помощник. Ключ хранится локально, зашифрован средствами Windows (DPAPI, только для вашей учётной записи).
$script:AsstJobs = @{}
$script:AsstSystem = @'
Ты встроенный помощник программы PC Doctor, которая диагностирует компьютер с Windows. Отвечай по-русски, простым языком, без жаргона, коротко (до 180 слов).
Измерения и состояние этого компьютера бери только из блока «Контекст», ничего не выдумывай. Если данных не хватает, скажи об этом.
На общие вопросы про Windows (где что найти, что значит настройка, как сделать) отвечай из своих знаний о Windows 10 и 11: пошагово, с точным путём по меню, и пометь, что это общее знание, а не данные отчёта. Если не уверен в названии пункта в конкретной версии, так и скажи.
Если шаг можно выполнить открытием окна Windows, добавь в конец ответа кнопки в виде меток [[open:имя]], где имя одно из: update (Центр обновления), optupd (дополнительные обновления и драйверы), devmgmt (Диспетчер устройств), network (параметры сети), wifi (Wi-Fi), ncpa (сетевые подключения), power (электропитание), startup (Диспетчер задач), apps (Приложения), router (страница роутера), display (дисплей), sound (звук), bluetooth, themes (темы), personal (персонализация), storage (память и хранилище), recovery (восстановление и сброс), about (о системе, версия Windows), gamemode (игровой режим), mouse (мышь), activation (активация), datetime (дата и время), language (язык), defaultapps (приложения по умолчанию), notif (уведомления), taskbar (панель задач), defender (Безопасность Windows), winver, diskmgmt (управление дисками), sysdm (свойства системы), cleanmgr (очистка диска), services (службы), eventvwr (просмотр событий), msinfo (сведения о системе). Других меток не используй.
На вопросы не про компьютер отвечай коротко, если знаешь ответ. У тебя нет доступа в интернет, поэтому актуальные курсы валют, новости, погоду и цены сказать не можешь: так и скажи и посоветуй посмотреть в надёжном источнике. Не изображай, что у тебя есть свежие данные.
Решение всегда за пользователем: предлагай варианты и объясняй последствия, не давай приказов.
Не советуй чистильщики реестра, отключение Защитника Windows или служб, твики реестра, автоматическую установку драйверов. Не обещай конкретный прирост FPS. Честно говори, что от настроек эффект обычно небольшой.
Если уместно, отсылай к кнопкам программы: «Исправить автоматически», «Открыть Диспетчер устройств», раздел «Очистка».
'@

function Settings-Path { Join-Path $script:AppDir 'settings.json' }
function Has-ApiKey { $s = Json-Read (Settings-Path) $null; return [bool]($s -and $s.apiKey) }
function Set-ApiKey($key) {
    $key = [string]$key
    if ($key.Length -gt 0 -and -not $key.Trim()) { return [ordered]@{ ok = $false; hasKey = (Has-ApiKey); message = 'Ключ состоит из пробелов. Вставьте ключ целиком.' } }
    if (-not $key.Trim()) { if (Test-Path -LiteralPath (Settings-Path)) { Remove-Item -LiteralPath (Settings-Path) -Force }; return [ordered]@{ ok = $true; hasKey = $false } }
    $enc = ConvertTo-SecureString -String $key.Trim() -AsPlainText -Force | ConvertFrom-SecureString
    Json-Write (Settings-Path) ([ordered]@{ apiKey = $enc })
    return [ordered]@{ ok = $true; hasKey = $true }
}

$script:AsstBlock = {
    param($enc, $bodyJson, $testUrl)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $sec = ConvertTo-SecureString $enc
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $h = @{ 'x-api-key' = $plain; 'anthropic-version' = '2023-06-01' }
        $url = 'https://api.anthropic.com/v1/messages'; if ($testUrl) { $url = $testUrl }
        # Windows PowerShell 5.1 читает JSON без charset как Latin-1 и ломает русский текст: берём байты и декодируем сами как UTF-8
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 90
        $bs = ([IO.MemoryStream]$resp.RawContentStream).ToArray()
        $r = ([Text.Encoding]::UTF8.GetString($bs)) | ConvertFrom-Json
        $txt = (@($r.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
        if (-not ([string]$txt).Trim()) { return @{ ok = $false; text = ('ИИ вернул пустой ответ (причина: ' + [string]$r.stop_reason + '). Попробуйте переформулировать вопрос или повторить.') } }
        return @{ ok = $true; text = $txt }
    } catch {
        $m = $_.Exception.Message; $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        $det = ''
        try { $d = [string]$_.ErrorDetails.Message; if (-not $d -and $_.Exception.Response) { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8); $d = $sr.ReadToEnd() }; if ($d) { $dj = $d | ConvertFrom-Json; if ($dj.error.message) { $det = [string]$dj.error.message } } } catch { }
        if ($code -eq 401 -or $m -match '\b401\b') { $m = 'Ключ не подошёл (ошибка 401). Проверьте ключ в настройках помощника.' }
        elseif ($code -eq 403) { $m = 'Доступ запрещён (403). Проверьте, что ключ действующий и у него есть права.' }
        elseif ($code -eq 429 -or $m -match '\b429\b') { $m = 'Слишком много запросов или закончились средства на ключе (429). Подождите минуту или проверьте баланс.' }
        elseif ($code -ge 500) { $m = 'Сервис ИИ сейчас недоступен (ошибка ' + $code + '). Попробуйте через пару минут.' }
        elseif ($m -match 'timed out|timeout|Timeout|время ожидания') { $m = 'ИИ не ответил вовремя. Попробуйте ещё раз.' }
        elseif ($m -match 'remote name|resolve|connect|подключ|соединени|сети|SSL|TLS|секретн') { $m = 'Нет связи с сервисом ИИ. Проверьте интернет (или VPN/антивирус) и повторите.' }
        elseif ($code -gt 0) { $m = 'Ошибка сервиса ИИ (' + $code + ')' + $(if ($det) { ': ' + $det } else { '' }) }
        else { $m = 'Не удалось получить ответ ИИ: ' + $m }
        return @{ ok = $false; text = $m }
    }
}

function Start-Assistant($messages, $context) {
    $id = [guid]::NewGuid().ToString()
    if ($script:MockMode) { $script:AsstJobs[$id] = @{ mock = $true; text = 'Это тестовый ответ помощника. В рабочем режиме здесь будет ответ ИИ по данным вашего отчёта.' }; return [ordered]@{ ok = $true; id = $id } }
    $s = Json-Read (Settings-Path) $null
    if (-not ($s -and $s.apiKey)) { return [ordered]@{ ok = $false; message = 'Ключ не задан.' } }
    $msgs = @(); foreach ($m in @($messages | Select-Object -Last 12)) { $msgs += @{ role = [string]$m.role; content = [string]$m.content } }
    while ($msgs.Count -gt 0 -and $msgs[0].role -ne 'user') { $msgs = @($msgs | Select-Object -Skip 1) }
    if ($msgs.Count -eq 0 -or $msgs[0].role -ne 'user') { return [ordered]@{ ok = $false; message = 'Пустой вопрос.' } }
    $ctxJson = ConvertTo-Json -InputObject $context -Depth 6 -Compress
    $body = @{ model = 'claude-haiku-5-5'; max_tokens = 1500; system = ($script:AsstSystem + "`nКонтекст (JSON):`n" + $ctxJson); messages = $msgs }
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 6 -Compress
    $job = Start-Job -ScriptBlock $script:AsstBlock -ArgumentList $s.apiKey, $bodyJson
    $script:AsstJobs[$id] = @{ job = $job }
    return [ordered]@{ ok = $true; id = $id }
}

function Get-AssistantResult($id) {
    if (-not $script:AsstJobs.ContainsKey($id)) { return [ordered]@{ done = $true; ok = $false; text = 'Запрос не найден.' } }
    $e = $script:AsstJobs[$id]
    if ($e.mock) { return [ordered]@{ done = $true; ok = $true; text = $e.text } }
    $j = $e.job
    if ($j.State -eq 'Running' -or $j.State -eq 'NotStarted') { return [ordered]@{ done = $false } }
    $r = $null; try { $r = Receive-Job -Job $j -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job -Job $j -Force } catch { }
    $script:AsstJobs.Remove($id)
    $r = @($r) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
    if ($r) { return [ordered]@{ done = $true; ok = [bool]$r.ok; text = [string]$r.text } }
    return [ordered]@{ done = $true; ok = $false; text = 'Не удалось получить ответ.' }
}
