# PC Doctor: поиск больших файлов на диске и удаление выбранного в Корзину. Файлы пользователя удаляются только по явному выбору на странице.
$script:ScanJob = $null
$script:ScanDrive = $null

$script:ScanBlock = {
    param($root, $minBytes, $outFile, $progFile)
    $skip = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information', 'Recovery', '$WinREAgent', 'Config.Msi', 'MSOCache')
    $catMap = @{}
    $progRx = '\\(Program Files[^\\]*|WindowsApps|Claude-Data|node_modules|claude-code|Versions|app-[\d.]+|Programs|Packages)\\|\\AppData\\(Local|Roaming)\\[^\\]+\\[^\\]+\.(exe|msi)$|^[A-Za-z]:\\Windows\\'
    $instRx = '^(?!.*uninstall).*(setup|install)'
    foreach ($e in 'mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'm4v', 'flv', 'mpg', 'mpeg') { $catMap[$e] = 'video' }
    foreach ($e in 'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'wma', 'aiff', 'opus') { $catMap[$e] = 'audio' }
    foreach ($e in 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'raw', 'psd', 'tif', 'tiff', 'cr2', 'nef', 'arw', 'dng') { $catMap[$e] = 'image' }
    foreach ($e in 'zip', 'rar', '7z', 'tar', 'gz', 'iso', 'img', 'bz2', 'xz') { $catMap[$e] = 'archive' }
    foreach ($e in 'exe', 'msi') { $catMap[$e] = 'installer' }
    foreach ($e in 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv') { $catMap[$e] = 'doc' }
    foreach ($e in 'safetensors', 'ckpt', 'gguf', 'pt', 'pth', 'onnx', 'bin') { $catMap[$e] = 'model' }
    $gameRx = '\\(steamapps|SteamLibrary|Epic Games|Riot Games|Battle\.net|Origin Games|EA Games|Ubisoft Game Launcher|Arena Breakout[^\\]*|Escape from Tarkov[^\\]*|XboxGames|WindowsApps|EasyAntiCheat|BattlEye)(\\|$)|\\Content\\Paks\\|\.(ucas|utoc)$'
    $projRx = '\\(\.git|node_modules|\.venv|venv|__pycache__)(\\|$)'
    $top = New-Object System.Collections.Generic.List[object]
    $dirs = @{}
    $catSize = @{}
    $catTop = @{}; $catMin = @{}
    $count = 0; $total = 0L
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    $rootLen = $root.TrimEnd('\').Length
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $di = New-Object IO.DirectoryInfo($d)
        try {
            foreach ($f in $di.GetFiles()) {
                $count++
                $len = [int64]$f.Length
                $total += $len
                $rel = $d.Substring([math]::Min($rootLen, $d.Length)).TrimStart('\')
                if ($rel) {
                    $parts = $rel.Split('\')
                    $k1 = $parts[0]
                    $dirs[$k1] = [int64]$dirs[$k1] + $len
                    if ($parts.Count -ge 2) { $k2 = $parts[0] + '\' + $parts[1]; $dirs[$k2] = [int64]$dirs[$k2] + $len }
                }
                $ext = $f.Extension.TrimStart('.').ToLower()
                $cat = 'other'; if ($catMap.ContainsKey($ext)) { $cat = $catMap[$ext] }; if ($cat -eq 'installer' -and ($f.FullName -match $progRx) -and ($f.Name -notmatch $instRx)) { $cat = 'program' }
                $catSize[$cat] = [int64]$catSize[$cat] + $len
                if ($cat -ne 'other' -and $len -gt 0 -and $len -ge [int64]$catMin[$cat]) {
                    $cf = $f.FullName
                    if (-not $catTop.ContainsKey($cat)) { $catTop[$cat] = New-Object System.Collections.Generic.List[object] }
                    $catTop[$cat].Add([ordered]@{ path = $cf; size = $len; mtime = $f.LastWriteTime.ToString('yyyy-MM-dd'); ext = $ext; cat = $cat
                            game = ($cf -match $gameRx); project = ($cf -match $projRx); model = ($cat -eq 'model') })
                    if ($catTop[$cat].Count -gt 600) { $sk = @($catTop[$cat] | Sort-Object { $_.size } -Descending | Select-Object -First 150); $nl = New-Object System.Collections.Generic.List[object]; $nl.AddRange($sk); $catTop[$cat] = $nl; $catMin[$cat] = [int64]$sk[$sk.Count - 1].size }
                }
                if ($len -ge $minBytes) {
                    $full = $f.FullName
                    $top.Add([ordered]@{ path = $full; size = $len; mtime = $f.LastWriteTime.ToString('yyyy-MM-dd'); ext = $ext; cat = $cat
                            game = ($full -match $gameRx); project = ($full -match $projRx); model = ($cat -eq 'model') })
                    if ($top.Count -gt 1500) { $s = @($top | Sort-Object { $_.size } -Descending | Select-Object -First 600); $top = New-Object System.Collections.Generic.List[object]; $top.AddRange($s) }
                }
                if (($count % 3000) -eq 0) { try { [IO.File]::WriteAllText($progFile, [string]$count) } catch { } }
            }
        } catch { }
        try {
            foreach ($s in $di.GetDirectories()) {
                if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($d.TrimEnd('\').Length -eq $rootLen -and ($skip -contains $s.Name)) { continue }
                $stack.Push($s.FullName)
            }
        } catch { }
    }
    $files = @($top | Sort-Object { $_.size } -Descending | Select-Object -First 300)
    $seenP = @{}; foreach ($x in $files) { $seenP[[string]$x.path] = $true }
    foreach ($ck in @($catTop.Keys)) { foreach ($x in @($catTop[$ck] | Sort-Object { $_.size } -Descending | Select-Object -First 150)) { if (-not $seenP.ContainsKey([string]$x.path)) { $seenP[[string]$x.path] = $true; $files += $x } } }
    $folders = @($dirs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40 | ForEach-Object { [ordered]@{ path = $_.Key; size = [int64]$_.Value } })
    $cats = @($catSize.GetEnumerator() | ForEach-Object { [ordered]@{ cat = $_.Key; size = [int64]$_.Value } })
    $res = [ordered]@{ drive = $root; scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm'); totalFiles = $count; totalBytes = $total; files = $files; folders = $folders; cats = $cats; catTop = $true }
    [IO.File]::WriteAllText($outFile, (ConvertTo-Json -InputObject $res -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Disk-File($drive) { Join-Path $script:AppDir ('bigfiles-' + $drive.Substring(0, 1).ToUpper() + '.json') }
function Disk-ValidDrive($drive) { return ([string]$drive -match '^[A-Za-z]:?\\?$') }

function Start-DiskScan($drive, $minMB) {
    if (-not (Disk-ValidDrive $drive)) { return [ordered]@{ ok = $false; message = 'Неверный диск.' } }
    if ($script:ScanJob -and $script:ScanJob.State -eq 'Running') { return [ordered]@{ ok = $false; message = 'Сканирование уже идёт.' } }
    $letter = $drive.Substring(0, 1).ToUpper()
    $root = $letter + ':\'
    if (-not $script:MockMode -and -not (Test-Path -LiteralPath $root)) { return [ordered]@{ ok = $false; message = 'Диск не найден.' } }
    $min = [int64]([math]::Max(10, [math]::Min(5000, [int]$minMB))) * 1MB
    $prog = Join-Path $script:AppDir 'scan-progress.txt'
    try { [IO.File]::WriteAllText($prog, '0') } catch { }
    if ($script:MockMode) {
        $mock = [ordered]@{ drive = $root; scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm'); totalFiles = 182340; totalBytes = 298000000000
            files = @(
                [ordered]@{ path = $letter + ':\Video\montage_2024_final.mp4'; size = 8200000000; mtime = '2024-03-02'; ext = 'mp4'; cat = 'video'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Music\Collection\album.flac'; size = 900000000; mtime = '2022-11-10'; ext = 'flac'; cat = 'audio'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\AI\models\flux1-dev.safetensors'; size = 23800000000; mtime = '2025-08-14'; ext = 'safetensors'; cat = 'model'; game = $false; project = $false; model = $true },
                [ordered]@{ path = $letter + ':\Downloads\Win11_installer.iso'; size = 5400000000; mtime = '2025-01-20'; ext = 'iso'; cat = 'archive'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Games\Steam\steamapps\common\Game\data.pak'; size = 12000000000; mtime = '2026-02-02'; ext = 'pak'; cat = 'other'; game = $true; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Photos\2023\IMG_0001.raw'; size = 310000000; mtime = '2023-07-01'; ext = 'raw'; cat = 'image'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Work\project-x\node_modules\big.bin'; size = 450000000; mtime = '2025-05-05'; ext = 'bin'; cat = 'model'; game = $false; project = $true; model = $true },
                [ordered]@{ path = $letter + ':\Music\Old\track01.mp3'; size = 9200000; mtime = '2019-05-05'; ext = 'mp3'; cat = 'audio'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Music\Old\track02.mp3'; size = 8100000; mtime = '2019-05-05'; ext = 'mp3'; cat = 'audio'; game = $false; project = $false; model = $false },
                [ordered]@{ path = $letter + ':\Docs\report.pdf'; size = 4300000; mtime = '2021-02-03'; ext = 'pdf'; cat = 'doc'; game = $false; project = $false; model = $false })
            catTop = $true
            folders = @([ordered]@{ path = 'AI'; size = 80000000000 }, [ordered]@{ path = 'Video'; size = 61000000000 }, [ordered]@{ path = 'Games'; size = 40000000000 }, [ordered]@{ path = 'Music'; size = 9000000000 })
            cats = @([ordered]@{ cat = 'model'; size = 80000000000 }, [ordered]@{ cat = 'video'; size = 61000000000 }, [ordered]@{ cat = 'other'; size = 50000000000 }, [ordered]@{ cat = 'audio'; size = 9000000000 }) }
        [IO.File]::WriteAllText((Disk-File $letter), (ConvertTo-Json -InputObject $mock -Depth 6), (New-Object Text.UTF8Encoding($false)))
        return [ordered]@{ ok = $true; message = 'Тестовое сканирование.' }
    }
    $script:ScanDrive = $letter
    $script:ScanJob = Start-Job -ScriptBlock $script:ScanBlock -ArgumentList $root, $min, (Disk-File $letter), $prog
    return [ordered]@{ ok = $true; message = 'Сканирование запущено.' }
}

function Get-DiskScanStatus {
    $running = ($script:ScanJob -and $script:ScanJob.State -eq 'Running')
    if ($script:ScanJob -and -not $running) { try { Remove-Job -Job $script:ScanJob -Force } catch { }; $script:ScanJob = $null }
    $n = 0; try { $n = [int](Get-Content -LiteralPath (Join-Path $script:AppDir 'scan-progress.txt') -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { }
    return [ordered]@{ running = [bool]$running; drive = $script:ScanDrive; files = $n }
}

function Get-DiskResult($drive) {
    if (-not (Disk-ValidDrive $drive)) { return $null }
    return (Json-Read (Disk-File $drive) $null)
}

function Get-FileLockInfo($p) {
    # Почему файл нельзя убрать: запущен как программа или занят другим процессом. Пустая строка: препятствий не видно.
    $r = ''
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $p } catch { $false } })
        if ($procs.Count -gt 0) { $r = ('Файл сейчас запущен как программа «' + $procs[0].ProcessName + '». Закройте её, в том числе значок у часов в трее, и повторите.') }
    } catch {}
    if (-not $r) {
        try { $fs = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close() }
        catch [System.UnauthorizedAccessException] { $r = 'Нет доступа к файлу. Попробуйте запуск через Admin.bat.' }
        catch [System.IO.IOException] { $r = 'Файл сейчас занят другой программой. Закройте программы, которые могли его открыть, и повторите.' }
        catch {}
    }
    return $r
}

function Bin-Check($path, $len) {
    # «В Корзину» на самом деле удаляет безвозвратно, если файл не помещается в Корзину или диск не внутренний
    try {
        $root = [IO.Path]::GetPathRoot([string]$path)
        $di = New-Object IO.DriveInfo($root)
        if ($di.DriveType -ne [IO.DriveType]::Fixed) { return 'Корзина работает только на внутренних дисках; удалите вручную' }
        if ($len -gt ($di.TotalSize * 0.08)) { return 'файл слишком большой для Корзины Windows (он удалился бы навсегда); удалите вручную' }
    } catch { }
    return $null
}
function Trash-Files($drive, $paths, [bool]$allowGame = $false) {
    if (-not (Disk-ValidDrive $drive)) { return [ordered]@{ ok = $false; message = 'Неверный диск.' } }
    $res = Json-Read (Disk-File $drive) $null
    if (-not $res) { return [ordered]@{ ok = $false; message = 'Сначала просканируйте диск.' } }
    $allowed = @{}
    $gameRx2 = '\\(steamapps|SteamLibrary|Epic Games|Riot Games|Battle\.net|Origin Games|EA Games|Ubisoft Game Launcher|Arena Breakout[^\\]*|Escape from Tarkov[^\\]*|XboxGames|WindowsApps|EasyAntiCheat|BattlEye)(\\|$)|\\Content\\Paks\\|\.(ucas|utoc)$'
    foreach ($f in @($res.files)) { if ($allowGame -or (-not $f.game -and ([string]$f.path -notmatch $gameRx2))) { $allowed[[string]$f.path] = $true } }
    $script:ProgRxT = '\\(Program Files[^\\]*|WindowsApps|Claude-Data|node_modules|claude-code|Versions|app-[\d.]+|Programs|Packages)\\|\\AppData\\(Local|Roaming)\\[^\\]+\\[^\\]+\.(exe|msi)$|^[A-Za-z]:\\Windows\\'
    $script:InstRxT = '^(?!.*uninstall).*(setup|install)'
    $script:InstLooseT = '\.msi$|\d+\.\d+\.\d+|(x64|x86|amd64|win32|win64|windows)'
    $script:SafeDirT = '\\(Downloads|Загрузки|Desktop|Рабочий стол)\\|\\AppData\\Local\\Temp\\'
    if (-not $script:MockMode) { Add-Type -AssemblyName Microsoft.VisualBasic }
    $done = 0; $bytes = 0L; $failed = @(); $blocked = @(); $delPaths = @()
    foreach ($p in @($paths)) {
        $p = [string]$p
        if (-not $allowed.ContainsKey($p)) { $failed += ($p + ' (нет в результатах сканирования или защищён)'); continue }
        $fnT = [IO.Path]::GetFileName($p); $instLike = (($fnT -match $script:InstRxT) -or (($p -notmatch $script:ProgRxT) -and ($fnT -match $script:InstLooseT)))
        $isBin = ($p -match '\.(exe|msi|dll|sys)$')
        $isProg = ($p -match $script:ProgRxT)
        $inSafe = ($p -match $script:SafeDirT)
        if ($isBin -and ((-not $instLike) -or ($isProg -and $fnT -notmatch '\.msi$') -or ((-not $inSafe) -and $fnT -notmatch '\.msi$'))) { $failed += ($p + ' (рабочий файл установленной программы, его удалять нельзя: программа перестанет запускаться)'); continue }
        try {
            if ($script:MockMode) { $done++; continue }
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $failed += ($p + ' (файл уже не найден)'); continue }
            $lk = Get-FileLockInfo $p
            if ($lk) { $failed += ($p + ' (' + $lk + ')'); $pn = $null; try { $pn = (Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $p } catch { $false } } | Select-Object -First 1).ProcessName } catch { }; if ($pn) { $blocked += [ordered]@{ path = $p; proc = $pn } }; continue }
            $len = (Get-Item -LiteralPath $p -Force).Length
            $bc = Bin-Check $p $len; if ($bc) { $failed += ($p + ' (' + $bc + ')'); continue }
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $done++; $bytes += $len; $delPaths += $p
        } catch { $failed += ($p + ' (' + $_.Exception.Message + ')') }
    }
    if ($done -gt 0) {
        Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); action = 'trash-files'; title = ('В Корзину отправлено файлов: ' + $done); undoable = ($delPaths.Count -gt 0); undone = $false; files = @($delPaths | Select-Object -First 300)
                result = ('Размер ' + [math]::Round($bytes / 1GB, 2) + ' ГБ. Вернуть можно из Корзины Windows.'); freedBytes = $bytes })
    }
    return [ordered]@{ ok = ($done -gt 0); deleted = $done; bytes = $bytes; failed = $failed; blocked = $blocked
        message = $(if ($done -eq 0 -and $failed.Count -gt 0) { 'Ничего не удалено. ' + (($failed | Select-Object -First 1) -replace '^.*\(', '' -replace '\)$', '') } else { 'В Корзину отправлено файлов: ' + $done + ', ' + [math]::Round($bytes / 1GB, 2) + ' ГБ. Место освободится после очистки Корзины. Вернуть файлы можно из Корзины.' + $(if ($failed.Count -gt 0) { ' Не удалось удалить: ' + $failed.Count + ' (подробности в окне).' } else { '' }) }) }
}

function Restore-FromBin($paths) {
    # Возвращает файлы из Корзины Windows на прежнее место. Ищем по исходной папке и имени, лишнего не трогаем.
    $want = @{}
    foreach ($p in @($paths)) { $want[([string]$p).ToLower()] = [string]$p }
    $total = $want.Count; $restored = 0
    try {
        $sh = New-Object -ComObject Shell.Application
        $bin = $sh.NameSpace(10)
        foreach ($it in @($bin.Items())) {
            if ($want.Count -eq 0) { break }
            $orig = ([string]$bin.GetDetailsOf($it, 1)).Replace([string][char]0x200E, '').Replace([string][char]0x200F, '').Trim()
            if (-not $orig) { continue }
            $nm = [string]$it.Name
            $ext = ''; try { $ext = [IO.Path]::GetExtension([string]$it.Path) } catch { }
            $hitKey = $null
            foreach ($c in @(($orig.TrimEnd('\') + '\' + $nm), ($orig.TrimEnd('\') + '\' + $nm + $ext))) { if ($want.ContainsKey($c.ToLower())) { $hitKey = $c.ToLower(); break } }
            if ($hitKey) {
                try { $it.InvokeVerb('undelete'); $restored++; $want.Remove($hitKey) } catch { }
            }
        }
    } catch { }
    return [ordered]@{ restored = $restored; total = $total }
}

function Stop-And-Trash($drive, $path) {
    # Пользователь нажал «Закрыть программу и удалить»: останавливаем только процессы, чей exe и есть этот файл
    $path = [string]$path
    $res = Json-Read (Disk-File $drive) $null
    if (-not $res -or @($res.files | Where-Object { [string]$_.path -eq $path }).Count -eq 0) { return [ordered]@{ ok = $false; message = 'Файла нет в результатах сканирования.' } }
    if ($script:MockMode) { return (Trash-Files $drive @($path) $false) }
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $path } catch { $false } })
    foreach ($pr in $procs) { if ($script:ProtectedProcs -contains $pr.ProcessName.ToLower()) { return [ordered]@{ ok = $false; message = ('«' + $pr.ProcessName + '» — системная или защищённая программа, закрывать её нельзя.') } } }
    foreach ($pr in $procs) { try { [void]$pr.CloseMainWindow(); Start-Sleep -Milliseconds 1500; $pr.Refresh(); if (-not $pr.HasExited) { Stop-Process -Id $pr.Id -Force -ErrorAction Stop } } catch { return [ordered]@{ ok = $false; message = ('Не удалось закрыть «' + $pr.ProcessName + '»: ' + $_.Exception.Message + ' Закройте её сами.') } } }
    Start-Sleep -Milliseconds 1200
    return (Trash-Files $drive @($path) $false)
}

function Reveal-File($drive, $path) {
    $res = Json-Read (Disk-File $drive) $null
    if (-not $res) { return $false }
    $ok = @($res.files | Where-Object { [string]$_.path -eq [string]$path }).Count -gt 0
    if ($ok -and -not $script:MockMode) { Start-Process 'explorer.exe' -ArgumentList ('/select,"' + $path + '"') }
    return $ok
}

# ---------- Папки «Загрузки» ----------
$script:DlGameRx = '\\(steamapps|SteamLibrary|Epic Games|Riot Games|Battle\.net|Origin Games|EA Games|Ubisoft Game Launcher|Arena Breakout[^\\]*|Escape from Tarkov[^\\]*|XboxGames|WindowsApps|EasyAntiCheat|BattlEye)(\\|$)|\\Content\\Paks\\|\.(ucas|utoc)$'
function Get-DownloadRoots($drive) {
    $L = ([string]$drive).Substring(0, 1).ToUpper()
    if ($script:MockMode) {
        if ($L -eq 'C') { return @('C:\Users\Zhenya\Downloads') }
        if ($L -eq 'D') { return @('D:\Downloads', 'D:\Загрузки') }
        return @()
    }
    $out = New-Object System.Collections.Generic.List[string]
    $add = { param($p) try { if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { $f = [IO.Path]::GetFullPath($p).TrimEnd('\'); if ($f.Substring(0, 1).ToUpper() -eq $L -and -not ($out | Where-Object { $_ -ieq $f })) { $out.Add($f) } } } catch { } }
    # настоящая папка «Загрузки» текущего пользователя (она может быть перенесена на другой диск)
    try { $sh = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads'); if ($sh) { & $add $sh.Self.Path } } catch { }
    & $add (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
    # на других дисках ищем папки с типичными названиями в корне и на один уровень глубже
    $rx = '^(downloads?|загрузки|скачанное|скачанные файлы|мои загрузки)$'
    $skip = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'Users', 'steamapps', 'SteamLibrary', 'Epic Games', 'XboxGames', 'WindowsApps', 'Games')
    try {
        $root = $L + ':\'
        foreach ($d1 in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d1.Name -match $rx) { & $add $d1.FullName; continue }
            if ($skip -contains $d1.Name) { continue }
            foreach ($d2 in (Get-ChildItem -LiteralPath $d1.FullName -Directory -Force -ErrorAction SilentlyContinue)) { if ($d2.Name -match $rx) { & $add $d2.FullName } }
        }
    } catch { }
    return @($out)
}
function Get-Downloads($drive) {
    if (-not (Disk-ValidDrive $drive)) { return [ordered]@{ roots = @(); files = @() } }
    $roots = @(Get-DownloadRoots $drive)
    if ($script:MockMode) {
        $mk = { param($p, $mb, $ageD, $ext) [ordered]@{ path = $p; size = [int64]($mb * 1MB); mtime = (Get-Date).AddDays(-$ageD).ToString('yyyy-MM-dd'); ext = $ext; cat = $(switch ($ext) { 'exe' { 'installer' } 'msi' { 'installer' } 'zip' { 'archive' } 'iso' { 'archive' } 'mp4' { 'video' } 'pdf' { 'doc' } 'jpg' { 'image' } default { 'other' } }); game = $false } }
        $f = @()
        if ($roots -contains 'C:\Users\Zhenya\Downloads') { $f = @(
            (& $mk 'C:\Users\Zhenya\Downloads\Docker Desktop Installer.exe' 620 40 'exe'), (& $mk 'C:\Users\Zhenya\Downloads\NVIDIA_app_v11.exe' 118 12 'exe'),
            (& $mk 'C:\Users\Zhenya\Downloads\project_backup.zip' 2400 210 'zip'), (& $mk 'C:\Users\Zhenya\Downloads\Win11_23H2.iso' 5400 300 'iso'),
            (& $mk 'C:\Users\Zhenya\Downloads\contract.pdf' 2 20 'pdf'), (& $mk 'C:\Users\Zhenya\Downloads\contract (1).pdf' 2 19 'pdf'),
            (& $mk 'C:\Users\Zhenya\Downloads\setup.exe.crdownload' 45 3 'crdownload'), (& $mk 'C:\Users\Zhenya\Downloads\screen.jpg' 3 400 'jpg')) }
        if ($roots -contains 'D:\Downloads') { $f = @(
            (& $mk 'D:\Downloads\Premiere_Pro_setup.exe' 1900 90 'exe'), (& $mk 'D:\Downloads\course_video.mp4' 3100 150 'mp4'), (& $mk 'D:\Загрузки\fonts.zip' 80 25 'zip')) }
        $rr = @($roots | ForEach-Object { $rp = $_; $ff = @($f | Where-Object { $_.path.StartsWith($rp, [StringComparison]::OrdinalIgnoreCase) }); [ordered]@{ path = $rp; size = [int64](($ff | Measure-Object size -Sum).Sum); count = $ff.Count } })
        return [ordered]@{ drive = $drive; roots = $rr; files = @($f | Sort-Object { $_.size } -Descending) }
    }
    $catMap = @{}
    $progRx = '\\(Program Files[^\\]*|WindowsApps|Claude-Data|node_modules|claude-code|Versions|app-[\d.]+|Programs|Packages)\\|\\AppData\\(Local|Roaming)\\[^\\]+\\[^\\]+\.(exe|msi)$|^[A-Za-z]:\\Windows\\'
    $instRx = '^(?!.*uninstall).*(setup|install)'
    foreach ($e in 'mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm') { $catMap[$e] = 'video' }
    foreach ($e in 'mp3', 'flac', 'wav', 'ogg', 'm4a') { $catMap[$e] = 'audio' }
    foreach ($e in 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'psd') { $catMap[$e] = 'image' }
    foreach ($e in 'zip', 'rar', '7z', 'tar', 'gz', 'iso', 'img') { $catMap[$e] = 'archive' }
    foreach ($e in 'exe', 'msi') { $catMap[$e] = 'installer' }
    foreach ($e in 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv') { $catMap[$e] = 'doc' }
    $files = New-Object System.Collections.Generic.List[object]
    $rootInfo = @()
    $cap = 20000; $seen = 0
    foreach ($r in $roots) {
        $rs = 0L; $rc = 0
        $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($r)
        while ($stack.Count -gt 0 -and $seen -lt $cap) {
            $d = $stack.Pop(); $di = New-Object IO.DirectoryInfo($d)
            try {
                foreach ($f in $di.GetFiles()) {
                    $seen++; $rc++; $len = [int64]$f.Length; $rs += $len
                    $ext = $f.Extension.TrimStart('.').ToLower(); $cat = 'other'; if ($catMap.ContainsKey($ext)) { $cat = $catMap[$ext] }; if ($cat -eq 'installer' -and ($f.FullName -match $progRx) -and ($f.Name -notmatch $instRx)) { $cat = 'program' }
                    $dt = $f.CreationTime; if ($f.LastWriteTime -gt $dt) { $dt = $f.LastWriteTime }
                    $files.Add([ordered]@{ path = $f.FullName; size = $len; mtime = $dt.ToString('yyyy-MM-dd'); ext = $ext; cat = $cat; game = ($f.FullName -match $script:DlGameRx) })
                    if ($files.Count -gt 3000) { $keep = @($files | Sort-Object { $_.size } -Descending | Select-Object -First 1200); $files = New-Object System.Collections.Generic.List[object]; $files.AddRange($keep) }
                }
            } catch { }
            try { foreach ($s2 in $di.GetDirectories()) { if (($s2.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s2.FullName) } } } catch { }
        }
        $rootInfo += [ordered]@{ path = $r; size = $rs; count = $rc }
    }
    return [ordered]@{ drive = $drive; roots = $rootInfo; files = @($files | Sort-Object { $_.size } -Descending | Select-Object -First 400); truncated = ($seen -ge $cap) }
}
function Test-InDownloads($drive, $path) {
    try {
        $full = [string]$path; if (-not $script:MockMode) { $full = [IO.Path]::GetFullPath($full) }
        foreach ($r in (Get-DownloadRoots $drive)) { if ($full.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    } catch { }
    return $false
}
function Trash-Downloads($drive, $paths) {
    if (-not (Disk-ValidDrive $drive)) { return [ordered]@{ ok = $false; message = 'Неверный диск.' } }
    if (-not $script:MockMode) { Add-Type -AssemblyName Microsoft.VisualBasic }
    $done = 0; $bytes = 0L; $failed = @()
    foreach ($p in @($paths)) {
        $p = [string]$p
        if (-not (Test-InDownloads $drive $p)) { $failed += ($p + ' (вне папки загрузок)'); continue }
        if ($p -match $script:DlGameRx) { $failed += ($p + ' (файл игры, защищён)'); continue }
        try {
            if ($script:MockMode) { $done++; continue }
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $failed += ($p + ' (файл уже не найден)'); continue }
            $lk = Get-FileLockInfo $p
            if ($lk) { $failed += ($p + ' (' + $lk + ')'); continue }
            $len = (Get-Item -LiteralPath $p -Force).Length
            $bc = Bin-Check $p $len; if ($bc) { $failed += ($p + ' (' + $bc + ')'); continue }
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $done++; $bytes += $len
        } catch { $failed += ($p + ' (' + $_.Exception.Message + ')') }
    }
    if ($done -gt 0) {
        Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); action = 'trash-downloads'; title = ('Из загрузок в Корзину: ' + $done + ' файлов'); undoable = $false; undone = $false
                result = ('Размер ' + [math]::Round($bytes / 1GB, 2) + ' ГБ. Вернуть можно из Корзины Windows.'); freedBytes = $bytes })
    }
    return [ordered]@{ ok = ($done -gt 0); deleted = $done; bytes = $bytes; failed = $failed
        message = $(if ($done -eq 0 -and $failed.Count -gt 0) { 'Ничего не удалено. ' + (($failed | Select-Object -First 1) -replace '^.*\(', '' -replace '\)$', '') } else { 'В Корзину отправлено файлов: ' + $done + ', ' + [math]::Round($bytes / 1GB, 2) + ' ГБ. Место освободится после очистки Корзины. Вернуть файлы можно из Корзины Windows.' + $(if ($failed.Count -gt 0) { ' Не удалось удалить: ' + $failed.Count + ' (подробности в окне).' } else { '' }) }) }
}
function Reveal-Download($drive, $path) {
    if (-not (Disk-ValidDrive $drive)) { return $false }
    $p = [string]$path
    $isRoot = @(Get-DownloadRoots $drive | Where-Object { $_ -ieq $p.TrimEnd('\') }).Count -gt 0
    if (-not ($isRoot -or (Test-InDownloads $drive $p))) { return $false }
    if (-not $script:MockMode) { if ($isRoot) { Start-Process 'explorer.exe' -ArgumentList ('"' + $p + '"') } else { Start-Process 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') } }
    return $true
}
